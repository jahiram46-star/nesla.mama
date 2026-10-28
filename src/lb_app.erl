%%%-------------------------------------------------------------------
%%% @doc Load Balancer Application Callback
%%% Starts required OTP applications (inets, ssl) and the supervisor.
%%% @end
%%%-------------------------------------------------------------------
-module(lb_app).
-behaviour(application).

-export([start/2, stop/1, start/0]).

%% Convenience starter from erl shell
start() ->
    application:ensure_all_started(load_balancer).

start(_StartType, _StartArgs) ->
    %% Ensure inets and ssl are started for HTTPS backend communication
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),

    %% Read configs with defaults
    Backends = application:get_env(load_balancer, backends, [
        {xano_prod_1, xano, "https://x8ki-letl-twmt.xano.io/api:v1"},
        {xano_prod_2, xano, "https://x8ki-letl-twmt.xano.io/api:v2"},
        {cloud_aws, cloud, "https://api.example-cloud-aws.com"},
        {cloud_gcp, cloud, "https://api.example-cloud-gcp.com"}
    ]),

    %% Rate limit: 10 requests per 1 minute (as requested by user)
    RatePerMin = application:get_env(load_balancer, rate_per_minute, 10),
    ListenPort = application:get_env(load_balancer, listen_port, 8080),

    logger:info("=== Starting Erlang Multi-Backend Load Balancer ==="),
    logger:info("Rate Limit : ~p requests / minute (~p ms interval)", [RatePerMin, (60 * 1000) div RatePerMin]),
    logger:info("Gateway Port: ~p", [ListenPort]),
    logger:info("Configured Backends: ~p", [length(Backends)]),

    lb_sup:start_link(Backends, RatePerMin, ListenPort).

stop(_State) ->
    ok.

