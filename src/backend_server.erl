-module(backend_server).
-export([start_all/0, start/1, stop/1]).
-export([accept_loop/2, handle_client/2]).

%% @doc Start 3 test backend HTTP servers on ports 9001, 9002, 9003
start_all() ->
    start(9001),
    start(9002),
    start(9003),
    io:format("~n>>> 3 Backend servers started on ports 9001, 9002, 9003! <<<~n~n").

%% @doc Start a single backend server on a given port
start(Port) ->
    case gen_tcp:listen(Port, [binary, {packet, 0}, {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            io:format("[Backend Server] Listening on port ~p~n", [Port]),
            spawn(fun() -> accept_loop(ListenSocket, Port) end),
            {ok, ListenSocket};
        {error, Reason} ->
            io:format("[Backend Server] Failed to listen on port ~p: ~p~n", [Port, Reason]),
            {error, Reason}
    end.

stop(ListenSocket) ->
    gen_tcp:close(ListenSocket).

accept_loop(ListenSocket, Port) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            spawn(fun() -> handle_client(Socket, Port) end),
            accept_loop(ListenSocket, Port);
        {error, _} ->
            ok
    end.

handle_client(Socket, Port) ->
    inet:setopts(Socket, [{active, false}]),
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, _Data} ->
            Body = io_lib:format("Response from Backend Server on Port: ~p~n", [Port]),
            BodyBinary = list_to_binary(Body),
            ContentLength = byte_size(BodyBinary),
            Response = io_lib:format(
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/plain\r\n"
                "Content-Length: ~p\r\n"
                "Connection: close\r\n"
                "\r\n~s",
                [ContentLength, BodyBinary]
            ),
            gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket);
        {error, _} ->
            gen_tcp:close(Socket)
    end.
