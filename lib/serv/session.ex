defmodule ServerSess do
    def init() do
        #send self(), :tick
        #has a uid
        #holds upstream tcp connections
        #holds a table for packets to send
        Mitme.Acceptor.start_link %{port: 9090, module: ServTcp, session: self()}
        {:ok, udpsocket} = ServerUdp.start 9090, self()


        send_queue = :ets.new :send_queue, [:ordered_set, :public, :named_table]

        state = %{
            remote_udp_endpoint: nil,
            send_queue: send_queue,
            send_counter: 0,
            last_send: 0,
            procs: %{},
            udpsocket: udpsocket,
        }

        #{:ok, state}
        loop state
    end

    def loop(state) do
        dispatch_packets(state.remote_udp_endpoint, state)

        state = receive do
            {:add_con, conn_id, dest_host, dest_port} ->
                #launch a connection
                {:ok, pid} = ServTcpCli.start {dest_host, dest_port}, conn_id, self()
                procs = Map.put state.procs, conn_id, %{proc: pid}
                %{state | procs: procs}

            {:con_data, conn_id, send_bytes} ->
                #send bytes to the tcp conn
                proc = Map.get state.procs, conn_id, nil
                case proc do
                    %{proc: proc} ->
                        send proc, {:send, send_bytes}
                    _ ->
                        nil
                end

                state

            {:ack_data, conn_id, data_num} ->
                :ets.delete state.send_queue, data_num
                state

            {:rm_con, conn_id} ->
                #kill a connection
                proc = Map.get state.procs, conn_id, nil
                case proc do
                    %{proc: proc} ->
                        Process.exit proc, :normal
                    _ ->
                        nil
                end
                procs = Map.delete state.procs, conn_id

                %{state | procs: procs}

            {:tcp_data, conn_id, d} ->
                IO.inspect {__MODULE__, "tcp data", conn_id, d}
                #add to the udp list
                :ets.insert state.send_queue, {state.send_counter, d}
                %{state | send_counter: state.send_counter + 1}

            {:tcp_connected, conn_id}
                #notify the other side
                state

            {:tcp_closed, conn_id} ->
                #notify the other side
                state

            {:udp_data, host, port, data} ->
                #TODO: verify the sessionid?
                #TODO: decrypt
                %{state | remote_udp_endpoint: {host, port}}

            a ->
                IO.inspect {:received, a}
                state

        after 1 ->
            state
        end
        
        __MODULE__.loop(state)
    end

    def dispatch_packets(nil, state) do
        state
    end
    def dispatch_packets({host, port}, state) do
        #do we have packets to send?
        #last ping?
        #pps ?
        if (state.last_send < state.send_counter) do
            case (:ets.lookup state.send_queue, state.last_send) do
                [{_, data}] ->
                    :gen_udp.send(state.socket, host, port, data)
                nil ->
                    nil
            end
            %{state | lastsend: state.last_send + 1}
        else
            state
        end
    end
end
