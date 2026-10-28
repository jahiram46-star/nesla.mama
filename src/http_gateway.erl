%%%-------------------------------------------------------------------
%%% @doc Frontend HTTP Gateway
%%% Accepts HTTP requests from frontend clients, parses requests,
%%% enqueues them into request_queue, and forwards backend responses.
%%% Includes full CORS support for browser frontends.
%%% @end
%%%-------------------------------------------------------------------
-module(http_gateway).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/0]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    listen_socket :: gen_tcp:socket() | undefined,
    port :: inet:port_number(),
    acceptor_pid :: pid() | undefined
}).

%%====================================================================
%% API Functions
%%====================================================================

start_link(Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Port, []).

stop() ->
    gen_server:stop(?MODULE).

%%====================================================================
%% gen_server Callbacks
%%====================================================================

init(Port) ->
    Opts = [
        binary,
        {packet, http_bin},
        {active, false},
        {reuseaddr, true},
        {backlog, 1024}
    ],
    case gen_tcp:listen(Port, Opts) of
        {ok, ListenSocket} ->
            Self = self(),
            AcceptorPid = spawn_link(fun() -> acceptor_loop(ListenSocket, Self) end),
            logger:info("HTTP Gateway listening on port ~p", [Port]),
            {ok, #state{listen_socket = ListenSocket, port = Port, acceptor_pid = AcceptorPid}};
        {error, Reason} ->
            logger:error("Failed to bind HTTP Gateway to port ~p: ~p", [Port, Reason]),
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen_socket = Sock}) ->
    if Sock =/= undefined -> gen_tcp:close(Sock); true -> ok end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Acceptor & Worker Loops
%%====================================================================

acceptor_loop(ListenSocket, Parent) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            Worker = spawn(fun() -> handle_client(Socket) end),
            gen_tcp:controlling_process(Socket, Worker),
            acceptor_loop(ListenSocket, Parent);
        {error, closed} ->
            ok;
        {error, Reason} ->
            logger:error("Accept error: ~p", [Reason]),
            timer:sleep(100),
            acceptor_loop(ListenSocket, Parent)
    end.

handle_client(Socket) ->
    inet:setopts(Socket, [{active, false}, {packet, http_bin}]),
    case gen_tcp:recv(Socket, 0, 15000) of
        {ok, {http_request, Method, Target, _Version}} ->
            Path = parse_target(Target),
            Headers = recv_headers(Socket, []),
            case recv_body(Socket, Headers) of
                {ok, Body} ->
                    process_http_request(Socket, normalize_method(Method), Path, Headers, Body);
                {error, invalid_content_length} ->
                    send_error_response(Socket, 400, <<"Invalid Content-Length">>)
            end;
        _ ->
            gen_tcp:close(Socket)
    end.

parse_target({abs_path, RawPathBin}) ->
    binary_to_list(RawPathBin);
parse_target({absoluteURI, _Scheme, _Host, _Port, RawPathBin}) ->
    binary_to_list(RawPathBin);
parse_target('*') ->
    "*";
parse_target(Other) when is_binary(Other) ->
    binary_to_list(Other);
parse_target(Other) when is_list(Other) ->
    Other;
parse_target(_) ->
    "/".

recv_headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} ->
            lists:reverse(Acc);
        {ok, {http_header, _, HeaderName, _, Value}} ->
            Key = header_key_to_list(HeaderName),
            Val = binary_to_list(Value),
            recv_headers(Socket, [{Key, Val} | Acc]);
        _ ->
            lists:reverse(Acc)
    end.

recv_body(Socket, Headers) ->
    LenVal = case lists:keyfind("Content-Length", 1, Headers) of
        false ->
            case lists:keyfind("content-length", 1, Headers) of
                false -> undefined;
                {_, Str1} -> Str1
            end;
        {_, Str0} -> Str0
    end,
    case LenVal of
        undefined ->
            {ok, <<>>};
        Str ->
            case catch list_to_integer(Str) of
                Len when is_integer(Len) andalso Len >= 0 ->
                    {ok, read_body_bytes(Socket, Len)};
                _ ->
                    {error, invalid_content_length}
            end
    end.

read_body_bytes(_Socket, 0) ->
    <<>>;
read_body_bytes(Socket, Length) ->
    inet:setopts(Socket, [{packet, raw}]),
    case gen_tcp:recv(Socket, Length, 15000) of
        {ok, Data} -> Data;
        _ -> <<>>
    end.

%%====================================================================
%% Request Routing & Processing
%%====================================================================

process_http_request(Socket, options, _Path, _Headers, _Body) ->
    %% Handle CORS preflight options
    CorsHeaders = [
        {"Access-Control-Allow-Origin", "*"},
        {"Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS"},
        {"Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With, X-Async"},
        {"Access-Control-Max-Age", "86400"}
    ],
    send_response(Socket, 204, CorsHeaders, <<>>);

process_http_request(Socket, get, "/health", _Headers, _Body) ->
    send_status_response(Socket);

process_http_request(Socket, get, "/status", _Headers, _Body) ->
    send_status_response(Socket);

process_http_request(Socket, Method, Path, Headers, Body) ->
    IsAsync = is_async_request(Headers, Path),
    case IsAsync of
        true ->
            %% Asynchronous dispatch: return 202 with ticket
            case request_queue:enqueue_async(Method, Path, Headers, Body) of
                {ok, Info} ->
                    Json = format_json_map(Info#{status => <<"queued">>}),
                    RespHeaders = [
                        {"Content-Type", "application/json"},
                        {"Access-Control-Allow-Origin", "*"}
                    ],
                    send_response(Socket, 202, RespHeaders, Json);
                {error, Reason} ->
                    send_error_response(Socket, 500, Reason)
            end;
        false ->
            %% Synchronous dispatch: line-by-line pacing
            case request_queue:enqueue_sync(Method, Path, Headers, Body, 60000) of
                {ok, StatusCode, RespHeaders, RespBody, BackendId, BackendType} ->
                    ForwardHeaders = [
                        {"Access-Control-Allow-Origin", "*"},
                        {"X-Served-By-Backend", val_to_string(BackendId)},
                        {"X-Backend-Type", val_to_string(BackendType)}
                        | filter_outgoing_headers(RespHeaders)
                    ],
                    send_response(Socket, StatusCode, ForwardHeaders, RespBody);
                {error, timeout} ->
                    send_error_response(Socket, 504, <<"Gateway Timeout - Request in queue exceeded timeout">>);
                {error, no_backends_available} ->
                    send_error_response(Socket, 503, <<"No Healthy Backends Available">>);
                {error, Reason} ->
                    send_error_response(Socket, 502, io_lib:format("Bad Gateway: ~p", [Reason]))
            end
    end.

%%====================================================================
%% Response Helpers
%%====================================================================

send_status_response(Socket) ->
    {ok, QueueStats} = request_queue:get_stats(),
    {ok, Backends} = backend_manager:list_backends(),
    ResponseMap = #{
        service => <<"Erlang Multi-Xano & Cloud Load Balancer">>,
        status => <<"healthy">>,
        rate_pacing => QueueStats,
        backends => Backends
    },
    Json = format_json_map(ResponseMap),
    Headers = [
        {"Content-Type", "application/json"},
        {"Access-Control-Allow-Origin", "*"}
    ],
    send_response(Socket, 200, Headers, Json).

send_error_response(Socket, StatusCode, Reason) ->
    ReasonBin = if
        is_binary(Reason) -> Reason;
        is_list(Reason) -> list_to_binary(Reason);
        true -> list_to_binary(io_lib:format("~p", [Reason]))
    end,
    Json = format_json_map(#{
        error => true,
        status_code => StatusCode,
        message => ReasonBin
    }),
    Headers = [
        {"Content-Type", "application/json"},
        {"Access-Control-Allow-Origin", "*"}
    ],
    send_response(Socket, StatusCode, Headers, Json).

send_response(Socket, StatusCode, Headers, Body) ->
    StatusText = status_code_to_text(StatusCode),
    StatusLine = io_lib:format("HTTP/1.1 ~p ~s\r\n", [StatusCode, StatusText]),
    BodyBin = if is_binary(Body) -> Body; is_list(Body) -> list_to_binary(Body); true -> <<>> end,
    LenHeader = io_lib:format("Content-Length: ~p\r\n", [byte_size(BodyBin)]),
    HdrLines = [io_lib:format("~s: ~s\r\n", [val_to_string(K), val_to_string(V)]) || {K, V} <- Headers],
    FullPacket = [StatusLine, HdrLines, LenHeader, "\r\n", BodyBin],
    gen_tcp:send(Socket, FullPacket),
    gen_tcp:close(Socket).

%%====================================================================
%% Utilities
%%====================================================================

val_to_string(Atom) when is_atom(Atom) -> atom_to_list(Atom);
val_to_string(Bin) when is_binary(Bin) -> binary_to_list(Bin);
val_to_string(List) when is_list(List) -> List;
val_to_string(Int) when is_integer(Int) -> integer_to_list(Int);
val_to_string(Other) -> io_lib:format("~p", [Other]).

normalize_method('GET') -> get;
normalize_method('POST') -> post;
normalize_method('PUT') -> put;
normalize_method('DELETE') -> delete;
normalize_method('PATCH') -> patch;
normalize_method('HEAD') -> head;
normalize_method('OPTIONS') -> options;
normalize_method(Other) when is_atom(Other) ->
    list_to_atom(string:to_lower(atom_to_list(Other)));
normalize_method(Other) when is_list(Other) ->
    list_to_atom(string:to_lower(Other));
normalize_method(Other) when is_binary(Other) ->
    list_to_atom(string:to_lower(binary_to_list(Other))).

header_key_to_list(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
header_key_to_list(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
header_key_to_list(List) when is_list(List) ->
    List.

is_async_request(Headers, Path) ->
    AsyncHeader = case lists:keyfind("X-Async", 1, Headers) of
        {_, "true"} -> true;
        _ ->
            case lists:keyfind("x-async", 1, Headers) of
                {_, "true"} -> true;
                _ -> false
            end
    end,
    AsyncQuery = string:str(Path, "async=true") > 0,
    AsyncHeader or AsyncQuery.

filter_outgoing_headers(Headers) ->
    lists:filter(fun({K, _}) ->
        Lower = string:to_lower(header_key_to_list(K)),
        Lower =/= "transfer-encoding" andalso
        Lower =/= "connection" andalso
        Lower =/= "content-length" andalso
        Lower =/= "access-control-allow-origin"
    end, Headers).

status_code_to_text(200) -> "OK";
status_code_to_text(201) -> "Created";
status_code_to_text(202) -> "Accepted";
status_code_to_text(204) -> "No Content";
status_code_to_text(400) -> "Bad Request";
status_code_to_text(404) -> "Not Found";
status_code_to_text(429) -> "Too Many Requests";
status_code_to_text(500) -> "Internal Server Error";
status_code_to_text(502) -> "Bad Gateway";
status_code_to_text(503) -> "Service Unavailable";
status_code_to_text(504) -> "Gateway Timeout";
status_code_to_text(_) -> "Response".

%% Simple pure Erlang JSON serializer without external libs
format_json_map(Map) when is_map(Map) ->
    Pairs = maps:to_list(Map),
    FormattedPairs = [
        io_lib:format("\"~s\": ~s", [to_str(K), to_json_val(V)])
        || {K, V} <- Pairs
    ],
    list_to_binary(["{", string:join(FormattedPairs, ", "), "}"]).

to_json_val(V) when is_map(V) -> format_json_map(V);
to_json_val(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> io_lib:format("\"~s\"", [escape_str(V)]);
        false ->
            JsonElements = [to_json_val(E) || E <- V],
            ["[", string:join(JsonElements, ", "), "]"]
    end;
to_json_val(V) when is_binary(V) -> io_lib:format("\"~s\"", [escape_str(binary_to_list(V))]);
to_json_val(true) -> "true";
to_json_val(false) -> "false";
to_json_val(V) when is_atom(V) -> io_lib:format("\"~s\"", [atom_to_list(V)]);
to_json_val(V) when is_integer(V) -> integer_to_list(V);
to_json_val(V) when is_float(V) -> io_lib:format("~.2f", [V]);
to_json_val(_) -> "null".

to_str(A) when is_atom(A) -> atom_to_list(A);
to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(L) when is_list(L) -> L.

escape_str(Str) ->
    lists:flatmap(fun
        ($") -> "\\\"";
        ($\\) -> "\\\\";
        ($\n) -> "\\n";
        ($\r) -> "\\r";
        ($\t) -> "\\t";
        (C) -> [C]
    end, Str).
