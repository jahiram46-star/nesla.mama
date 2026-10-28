%%%-------------------------------------------------------------------
%%% @doc Request Dispatcher
%%% Dispatches HTTP requests to chosen backend (Xano / Cloud).
%%% Automatically handles retries and reports backend health.
%%% @end
%%%-------------------------------------------------------------------
-module(dispatcher).

-export([dispatch/5, execute_request/6]).

%% Maximum retries on server/connection failure
-define(MAX_RETRIES, 2).
-define(HTTP_TIMEOUT_MS, 15000).

-spec dispatch(atom(), string(), [{string(), string()}], binary(), any()) ->
    {ok, integer(), [{string(), string()}], binary()} | {error, term()}.
dispatch(Method, Path, Headers, Body, From) ->
    case backend_manager:get_next_backend() of
        {ok, {BackendId, BackendType, BaseUrl}} ->
            Result = execute_with_retry(Method, BaseUrl, Path, Headers, Body, BackendId, ?MAX_RETRIES),
            case Result of
                {ok, StatusCode, RespHeaders, RespBody} ->
                    reply(From, {ok, StatusCode, RespHeaders, RespBody, BackendId, BackendType}),
                    {ok, StatusCode, RespHeaders, RespBody};
                {error, Reason} ->
                    reply(From, {error, Reason}),
                    {error, Reason}
            end;
        {error, Reason} ->
            reply(From, {error, Reason}),
            {error, Reason}
    end.

%% Dispatch with retries across backends if a backend is dead
execute_with_retry(Method, BaseUrl, Path, Headers, Body, BackendId, RetriesLeft) ->
    FullUrl = BaseUrl ++ Path,
    case execute_request(Method, FullUrl, Headers, Body, BackendId, ?HTTP_TIMEOUT_MS) of
        {ok, StatusCode, RespHeaders, RespBody} when StatusCode < 500 ->
            backend_manager:report_status(BackendId, success),
            {ok, StatusCode, RespHeaders, RespBody};
        {ok, StatusCode, RespHeaders, RespBody} when StatusCode >= 500 andalso RetriesLeft > 0 ->
            backend_manager:report_status(BackendId, failure),
            %% Try another backend
            case backend_manager:get_next_backend() of
                {ok, {NextId, _Type, NextBaseUrl}} ->
                    execute_with_retry(Method, NextBaseUrl, Path, Headers, Body, NextId, RetriesLeft - 1);
                _ ->
                    {ok, StatusCode, RespHeaders, RespBody}
            end;
        {ok, StatusCode, RespHeaders, RespBody} ->
            backend_manager:report_status(BackendId, success),
            {ok, StatusCode, RespHeaders, RespBody};
        {error, Reason} when RetriesLeft > 0 ->
            backend_manager:report_status(BackendId, failure),
            case backend_manager:get_next_backend() of
                {ok, {NextId, _Type, NextBaseUrl}} ->
                    execute_with_retry(Method, NextBaseUrl, Path, Headers, Body, NextId, RetriesLeft - 1);
                _ ->
                    {error, Reason}
            end;
        {error, Reason} ->
            backend_manager:report_status(BackendId, failure),
            {error, Reason}
    end.

execute_request(Method, FullUrl, Headers, Body, _BackendId, Timeout) ->
    CleanHeaders = filter_headers(Headers),
    HttpOpt = [{timeout, Timeout}, {connect_timeout, 5000}],
    ReqOpt = [{body_format, binary}],

    ReqResult = case Method of
        get ->
            httpc:request(get, {FullUrl, CleanHeaders}, HttpOpt, ReqOpt);
        delete ->
            httpc:request(delete, {FullUrl, CleanHeaders}, HttpOpt, ReqOpt);
        head ->
            httpc:request(head, {FullUrl, CleanHeaders}, HttpOpt, ReqOpt);
        options ->
            httpc:request(options, {FullUrl, CleanHeaders}, HttpOpt, ReqOpt);
        _Other -> %% post, put, patch
            ContentType = extract_content_type(CleanHeaders),
            httpc:request(Method, {FullUrl, CleanHeaders, ContentType, Body}, HttpOpt, ReqOpt)
    end,

    case ReqResult of
        {ok, {{_Version, StatusCode, _ReasonPhrase}, RespHeaders, RespBody}} ->
            {ok, StatusCode, RespHeaders, RespBody};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

reply(async, _Result) ->
    ok;
reply(From, Result) when is_tuple(From) ->
    gen_server:reply(From, Result);
reply(_From, _Result) ->
    ok.

extract_content_type(Headers) ->
    case lists:keyfind("content-type", 1, Headers) of
        {_, Val} -> Val;
        false ->
            case lists:keyfind("Content-Type", 1, Headers) of
                {_, Val2} -> Val2;
                false -> "application/json"
            end
    end.

%% Filter out host and connection headers so httpc manages its own
filter_headers(Headers) ->
    lists:filter(fun({Key, _Val}) ->
        Lower = string:to_lower(Key),
        Lower =/= "host" andalso Lower =/= "connection" andalso Lower =/= "content-length"
    end, Headers).
