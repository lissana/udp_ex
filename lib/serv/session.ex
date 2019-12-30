defmodule ServerSess do
    def init() do
        #send self(), :tick
        #has a uid
        #holds upstream tcp connections
        #holds a table for packets to send
        Mitme.Acceptor.start_link %{port: 9090, module: ServTcp, session: self()}

        send_queue = :ets.new :send_queue, [:ordered_set]

        state = %{
            remote_udp_endpoint: nil,
            send_queue: send_queue,
            send_counter: 0,
            last_send: 0,
            procs: %{},
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
                :ets.insert state.send_queue, {state.send_counter, }
                %{state | send_counter: state.send_counter + 1}

            {:tcp_connected, conn_id}
                #notify the other side
                state

            {:tcp_closed, conn_id} ->
                #notify the other side
                state

            a ->
                IO.inspect {:received, a}
                state
                
        after 1 ->
            state
        end
        loop(state)
    end

    def dispatch_packets(nil, state) do state end
    def dispatch_packets({host, port}, state) do
        #do we have packets to send?
        #last ping?
        #pps ?
        bin = :ets.next state.send_queue

        :gen_udp.send(state.socket, host, port, bin)

        state
    end
end
