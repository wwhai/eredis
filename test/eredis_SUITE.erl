%% @author: 
%% @description: 
-module(eredis_SUITE).
-include_lib("eunit/include/eunit.hrl").
-include("eredis.hrl").

-compile([export_all, nowarn_export_all]).
%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------
all() ->
    [{group, ssl}].
groups() ->
    Cases = [get_set_test,
             delete_test,
             mset_mget_test,
             exec_test,
             exec_nil_test,
             pipeline_test,
             pipeline_mixed_test,
             q_noreply_test,
             q_async_test],
    [{ssl, Cases}].
init_per_suite(_Cfg) ->
    _Cfg.

end_per_suite(_) ->
    ok.

init_per_group(Group , Cfg) ->
    [{t, Group}| Cfg].

end_per_group(_Group, _Cfg) ->
    ok.
%%--------------------------------------------------------------------

connect_ssl() ->
    Options = [{ssl_options, [{cacertfile, "/Users/wangwenhai/github/emqx-enterprise-rel/_checkouts/eredis/test/eredis_SUITE_data/certs/ca.crt"},
                              {certfile, "/Users/wangwenhai/github/emqx-enterprise-rel/_checkouts/eredis/test/eredis_SUITE_data/certs/redis.crt"},
                              {keyfile, "/Users/wangwenhai/github/emqx-enterprise-rel/_checkouts/eredis/test/eredis_SUITE_data/certs/redis.key"}]},
               {tcp_options ,[{reuseaddr, true}]}],
    {ok, SSLClient} = eredis:start_link("127.0.0.1", 6379, 0, "", 3000, 5000, Options),
    SSLClient.

connect_tcp() ->
    {ok, TcpClient} = eredis:start_link("127.0.0.1", 6379),
    TcpClient.

c(T) ->
    case T of
        tcp -> C = connect_tcp(), eredis:q(C, ["flushdb"]), C;
        ssl -> C = connect_ssl(), eredis:q(C, ["flushdb"]), C
    end.

get_set_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL", foo])),
    ?assertEqual({ok, undefined}, eredis:q(C, ["GET", foo])),
    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["SET", foo, bar])),
    ?assertEqual({ok, <<"bar">>}, eredis:q(C, ["GET", foo])).


delete_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL", foo])),

    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["SET", foo, bar])),
    ?assertEqual({ok, <<"1">>}, eredis:q(C, ["DEL", foo])),
    ?assertEqual({ok, undefined}, eredis:q(C, ["GET", foo])).

mset_mget_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),
    Keys = lists:seq(1, 10),

    ?assertMatch({ok, _}, eredis:q(C, ["DEL" | Keys])),

    KeyValuePairs = [[K, K*2] || K <- Keys],
    ExpectedResult = [list_to_binary(integer_to_list(K * 2)) || K <- Keys],

    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["MSET" | lists:flatten(KeyValuePairs)])),
    ?assertEqual({ok, ExpectedResult}, eredis:q(C, ["MGET" | Keys])),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL" | Keys])).

exec_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),

    ?assertMatch({ok, _}, eredis:q(C, ["LPUSH", "k1", "b"])),
    ?assertMatch({ok, _}, eredis:q(C, ["LPUSH", "k1", "a"])),
    ?assertMatch({ok, _}, eredis:q(C, ["LPUSH", "k2", "c"])),

    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["MULTI"])),
    ?assertEqual({ok, <<"QUEUED">>}, eredis:q(C, ["LRANGE", "k1", "0", "-1"])),
    ?assertEqual({ok, <<"QUEUED">>}, eredis:q(C, ["LRANGE", "k2", "0", "-1"])),

    ExpectedResult = [[<<"a">>, <<"b">>], [<<"c">>]],

    ?assertEqual({ok, ExpectedResult}, eredis:q(C, ["EXEC"])),

    ?assertMatch({ok, _}, eredis:q(C, ["DEL", "k1", "k2"])).

exec_nil_test(Config) ->
    C1 = c(proplists:get_value(t, Config, tcp)),
    C2 = c(proplists:get_value(t, Config, tcp)),

    ?assertEqual({ok, <<"OK">>}, eredis:q(C1, ["WATCH", "x"])),
    ?assertMatch({ok, _}, eredis:q(C2, ["INCR", "x"])),
    ?assertEqual({ok, <<"OK">>}, eredis:q(C1, ["MULTI"])),
    ?assertEqual({ok, <<"QUEUED">>}, eredis:q(C1, ["GET", "x"])),
    ?assertEqual({ok, undefined}, eredis:q(C1, ["EXEC"])),
    ?assertMatch({ok, _}, eredis:q(C1, ["DEL", "x"])).

pipeline_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),

    P1 = [["SET", a, "1"],
          ["LPUSH", b, "3"],
          ["LPUSH", b, "2"]],

    ?assertEqual([{ok, <<"OK">>}, {ok, <<"1">>}, {ok, <<"2">>}],
                 eredis:qp(C, P1)),

    P2 = [["MULTI"],
          ["GET", a],
          ["LRANGE", b, "0", "-1"],
          ["EXEC"]],

    ?assertEqual([{ok, <<"OK">>},
                  {ok, <<"QUEUED">>},
                  {ok, <<"QUEUED">>},
                  {ok, [<<"1">>, [<<"2">>, <<"3">>]]}],
                 eredis:qp(C, P2)),

    ?assertMatch({ok, _}, eredis:q(C, ["DEL", a, b])).

pipeline_mixed_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),
    P1 = [["LPUSH", c, "1"] || _ <- lists:seq(1, 100)],
    P2 = [["LPUSH", d, "1"] || _ <- lists:seq(1, 100)],
    Expect = [{ok, list_to_binary(integer_to_list(I))} || I <- lists:seq(1, 100)],
    spawn(fun () ->
                  erlang:yield(),
                  ?assertEqual(Expect, eredis:qp(C, P1))
          end),
    spawn(fun () ->
                  ?assertEqual(Expect, eredis:qp(C, P2))
          end),
    timer:sleep(10),
    ?assertMatch({ok, _}, eredis:q(C, ["DEL", c, d])).

q_noreply_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),
    ?assertEqual(ok, eredis:q_noreply(C, ["GET", foo])),
    ?assertEqual(ok, eredis:q_noreply(C, ["SET", foo, bar])),
    %% Even though q_noreply doesn't wait, it is sent before subsequent requests:
    ?assertEqual({ok, <<"bar">>}, eredis:q(C, ["GET", foo])).
q_async_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),
    ?assertEqual({ok, <<"OK">>}, eredis:q(C, ["SET", foo, bar])),
    ?assertEqual(ok, eredis:q_async(C, ["GET", foo], self())),
    receive
        {response, Msg} ->
            ?assertEqual(Msg, {ok, <<"bar">>}),
            ?assertMatch({ok, _}, eredis:q(C, ["DEL", foo]))
    end.

undefined_database_test() ->
    ?assertMatch({ok,_}, eredis:start_link("localhost", 6379, undefined)).

tcp_closed_test(Config) ->
    C = c(proplists:get_value(t, Config, tcp)),
    tcp_closed_rig(C).

tcp_closed_rig(C) ->

    DoSend = fun(tcp_closed) ->
                     C ! {tcp_closed, fake_socket};
                (Cmd) ->
                     eredis:q(C, Cmd)
             end,
    %% attach an id to each message for later
    Msgs = [{1, ["GET", "foo"]},
            {2, ["GET", "bar"]},
            {3, tcp_closed}],
    Pids = [ remote_query(DoSend, M) || M <- Msgs ],
    Results = gather_remote_queries(Pids),
    ?assertEqual({error, tcp_closed}, proplists:get_value(1, Results)),
    ?assertEqual({error, tcp_closed}, proplists:get_value(2, Results)).

remote_query(Fun, {Id, Cmd}) ->
    Parent = self(),
    spawn(fun() ->
                  Result = Fun(Cmd),
                  Parent ! {self(), Id, Result}
          end).

gather_remote_queries(Pids) ->
    gather_remote_queries(Pids, []).

gather_remote_queries([], Acc) ->
    Acc;
gather_remote_queries([Pid | Rest], Acc) ->
    receive
        {Pid, Id, Result} ->
            gather_remote_queries(Rest, [{Id, Result} | Acc])
    after
        10000 ->
            error({gather_remote_queries, timeout})
    end.