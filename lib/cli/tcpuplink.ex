defmodule TcpUplink do
    def start {remotehost, remoteport}, sessionid, session do
        GenServer.start __MODULE__, %{
            remotehost: remotehost,
            remoteport: remoteport,
            sessionid: sessionid,
            session: session
        }
    end

    def init(args) do
        send self(), :connect
        state = Map.merge args, %{socket: nil}
        {:ok, state}
    end

    def handle_info(:connect, state) do
        IO.inspect {__MODULE__, :connecting}
        #connect
        rc4stream_s = :crypto.stream_init :rc4, "some_random_pass"
        rc4stream_d = :crypto.stream_init :rc4, "some_random_pass"

        {:ok, serverSocket} = :gen_tcp.connect :binary.bin_to_list(state.remotehost), state.remoteport, [{:active, false}, :binary]

        {rc4stream_s, decoded} = :crypto.stream_encrypt rc4stream_s, <<
            0, sessionid::64-little, 0::64, 0::64, 0::64, 0::64,
        >>
        {rc4stream_s, decoded} = :crypto.stream_encrypt rc4stream_d, to_dec
        :gen_tcp.send serverSocket, decoded
        {:ok, _} = :gen_tcp.recv serverSocket, 0
        #send initial rc4 key
        #send session id
        #receive hello

        state = Map.merge state, %{
            rc4stream_d: rc4stream_d,
            rc4stream_s: rc4stream_s,
            socket: socket
        }

        {:noreply, state}
    end

    def handle_info({:tcp_close, socket}, state) do
        :erlang.send_after 1000, self(), :connect

        {:noreply, state}
    end

    def handle_info({:send, data}, state) do
        IO.inspect {:should_send_data, data}

        {rc4stream_s, encoded} = :crypto.stream_encrypt state.rc4stream_d, data

        :gen_tcp.send state.socket, encoded

        {:noreply, state}
    end
end
