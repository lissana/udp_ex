defmodule ClientSess do
    use GenServer

    def start(args \\ %{}) do
        GenServer.start __MODULE__, args
    end

    def init(args) do
        remotehost = "52.79.227.216"
        remoteport = 9090

        {a,b,c} = :erlang.now
        sessionid = a*1000 + b

        {:ok, udpsocket} = UdpClient.start 9908, self()
        {:ok, tcpuplink} = TcpUplink.start {remotehost, remoteport}, sessionid, self()
        Mitme.Acceptor.start_link %{port: 9080, module: CliConn, session: self()}

        state = %{
            remotehost: remotehost,
            remoteport: remoteport,
            remote_udp_endpoint: nil,
            tcp_procs: %{},
            next_conn_id: 0,
            udp_proc: nil,
            udpsocket: udpsocket,
            sessionid: sessionid,
            tcpuplink: tcpuplink,
            buckets: [],
            last_req_again: {0,0,0},
        }
        send self(), :tick
        {:ok, state}
    end

    def handle_info(:tick, state) do
        :erlang.send_after 5000, self(), :tick

        #send udp ping with session id
        {a,b,c} = :erlang.now
        curtime = a*1000000 + b
        :gen_udp.send state.udpsocket, :binary.bin_to_list(state.remotehost), state.remoteport, <<curtime::64-little>>

        {:noreply, state}
    end

    def handle_info({:tcp_data, proc, data}, state) do

        fproc = Enum.find state.tcp_procs, fn({_, aconn})-> aconn.proc == proc end
        #send to tcp uplink
        case fproc do
            {_, %{conn_id: next_conn_id}} ->
                send state.tcpuplink, {:send, <<
                    2, #data
                    next_conn_id :: 64-little,
                    byte_size(data)::32-little,
                >> <> data}
            _ ->
                Process.exit proc, :normal
                IO.inspect {__MODULE__, :zombi_conn_data, proc}
        end

        {:noreply, state}
    end

    def handle_info({:tcp_add, proc, dest_host, dest_port}, state) do
        next_conn_id = state.next_conn_id

        #add a monitor to the tcp proc

        tcp_procs = Map.put state.tcp_procs, next_conn_id, %{
            proc: proc, conn_id: next_conn_id
        }

        send state.tcpuplink, {:send, <<
            1, #connect
            next_conn_id :: 64-little,
            byte_size(dest_host),
            dest_host::binary,
            dest_port::16-little
        >>}

        state = %{state | next_conn_id: next_conn_id + 1, tcp_procs: tcp_procs}
        {:noreply, state}
    end

    def handle_info({:tcp_closed, proc}, state) do
        s = Enum.find state.tcp_procs, fn({_, aconn})-> aconn.proc == proc end
        case s do
            {_, %{conn_id: next_conn_id}} ->

                send state.tcpuplink, {:send, <<
                    3, #close
                    next_conn_id :: 64-little,
                >>}

                tcp_procs = Map.delete state.tcp_procs, next_conn_id
                state = %{state | tcp_procs: tcp_procs}

            _ ->
                nil
        end

        {:noreply, state}
    end

    def handle_info({:udp_data, host, port, bin}, state) do
        # {_, %{conn_id: next_conn_id}} = Enum.find state.tcp_procs, fn({_, aconn})-> aconn.proc == proc end
        #
        # send state.tcpuplink, {:send, <<
        #     3, #close
        #     next_conn_id :: 64-little,
        # >>}

        #IO.inspect {"received udp data", bin}

        << packet_id::64-little, data :: binary>> = bin

        {is_new, nbuckets} = add_to_sparse([], state.buckets, packet_id)

        ack_data state, packet_id

        case is_new do
            :ok ->
                newpackets = Process.get :news, 0
                Process.put :news, newpackets + 1
            _ ->
                dups = Process.get :dups, 0
                Process.put :dups, dups + 1
        end

        state = Map.put state, :buckets, nbuckets



        last_req_again = state.last_req_again
        now = :erlang.timestamp
        #if congestion too high, make the retry req 1 s
        state = if (:timer.now_diff(now, last_req_again) > 3000000) do
            #IO.inspect state.buckets
            IO.inspect {:req_again, now,
                    Process.get(:dups, 0),
                    Process.get(:news, 0)
                    }
            case state.buckets do
                [{_x, 0}] ->
                    :nothing
                other ->
                    {a, b} = :lists.last other
                    a = if b != 0 do 0 else a + 1 end
                    req_again state, a
            end
            state = Map.put state, :last_req_again, now
        else
            state
        end

        state = proc_udp_packet(data, state)

        {:noreply, state}
    end

    def proc_udp_packet(<<1, conn_id::64-little, offset::64-little, data :: binary>>, state) do

        proc = Map.get state.tcp_procs, conn_id, nil
        case proc do
            %{proc: pid} ->
                send pid, {:queue, offset, data}
            _ ->
                IO.inspect {__MODULE__, :PROC_NOT_FOUND, state.tcp_procs}
                nil
        end

        state
    end

    def proc_udp_packet(<<3, conn_id::64-little, sent::64-little>>, state) do

        proc = Map.get state.tcp_procs, conn_id, nil
        case proc do
            %{proc: pid} ->
                send pid, {:close_conn, sent}
            _ ->
                #IO.inspect {__MODULE__, :PROC_NOT_FOUND, state.tcp_procs}
                nil
        end

        state
    end

    def ack_data(state, data_frame) do
        send state.tcpuplink, {:send, <<
            4, #ack data
            0 :: 64-little,
            data_frame :: 64-little
        >>}
    end

    def req_again(state, data_frame) do
        send state.tcpuplink, {:send, <<
            5, #ack data
            0 :: 64-little,
            data_frame :: 64-little
        >>}
    end

    def add_to_sparse(h, [], packetid) do
        {:ok, merge_sparse(h, [{packetid, packetid}])}
    end

    def add_to_sparse(h, [{s0, s1} | t] = origt, packetid) when packetid <= s0 and packetid >= s1 do
        {:already_exists, merge_sparse(h, origt)}
    end

    def add_to_sparse(h, [{s0, s1} | t], packetid) when packetid == s0 + 1 do
        {:ok, merge_sparse(h, [{packetid, s1} | t])}
    end

    def add_to_sparse(h, [{s0, s1} | t], packetid) when packetid > s0 do
        {:ok, merge_sparse(h, [{packetid, packetid}, {s0, s1} | t])}
    end

    def add_to_sparse(h, [{s0, s1} | t], packetid) when packetid < s1 do
        add_to_sparse([{s0, s1} | h], t, packetid)
    end

    def merge_sparse [], rest do
        rest
    end

    def merge_sparse([{big0, small0} | resth], [{big1, small1} | restl]) when small0 == big1 + 1 do
        :lists.reverse([{big0, small1} | resth]) ++ restl
    end

    def merge_sparse h, l do
        :lists.reverse(h) ++ l
    end

    def test() do
        {:ok, [{0,0}]} = ClientSess.add_to_sparse [], [], 0

        {:ok, s} = ClientSess.add_to_sparse [], [], 1
        IO.inspect s
        {:ok, s} = ClientSess.add_to_sparse [], s, 3
        IO.inspect s
        {:ok, s} = ClientSess.add_to_sparse [], s, 4
        IO.inspect s
        {:ok, s} = ClientSess.add_to_sparse [], s, 7
        IO.inspect s
        {:ok, s} = ClientSess.add_to_sparse [], s, 10
        IO.inspect s

        {:ok, s} = ClientSess.add_to_sparse [], s, 5
        IO.inspect s

        {:ok, s} = ClientSess.add_to_sparse [], s, 6
        IO.inspect s

        {:already_exists, s} = ClientSess.add_to_sparse [], s, 6
        IO.inspect s

        {:already_exists, s} = ClientSess.add_to_sparse [], s, 1
        IO.inspect s

        {:ok, s} = ClientSess.add_to_sparse [], s, 2
        IO.inspect s

        {:ok, s} = ClientSess.add_to_sparse [], s, 8
        IO.inspect s

        {:ok, s} = ClientSess.add_to_sparse [], s, 9
        IO.inspect s

        {:ok, s} = ClientSess.add_to_sparse [], s, 0
        IO.inspect s
    end
end
