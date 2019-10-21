%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%%     dpg (distributed process groups)
%%% @end
%%% -------------------------------------------------------------------
-module(stateless_service_SUITE).
-author("maximfca@gmail.com").

%% Test server callbacks
-export([
    suite/0,
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2
]).

%% Test cases exports
-export([
    local/0, local/1,
    docker/0, docker/1
]).

%% Internal exports: nodes loops, control loops, bootstrap
-export([
    smoke_control/2
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/logger.hrl").

-define (NODE_COUNT, 2).

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    % build docker image
    case build(Config) of
        undefined ->
            [{node_count, ?NODE_COUNT} | Config];
        Image ->
            [{node_count, ?NODE_COUNT}, {image, Image} | Config]
    end.

end_per_suite(Config) ->
    % remove image
    proplists:get_value(image, Config) =/= undefined andalso
        os:cmd("docker rmi " ++ proplists:get_value(image, Config)),
    Config.

init_per_testcase(docker, Config) ->
    case proplists:get_value(image, Config, undefined) of
        undefined ->
            {skip, "Docker image cannot be built, ensure you have docker installed and running"};
        Img when is_list(Img) ->
            Config
    end;
init_per_testcase(_, Config) ->
    Config.

all() ->
    [local, docker].

%%--------------------------------------------------------------------
%% Helpers

%% Container start: no container, just a separate BEAM
start_local(SName, ExtraArgs) ->
    DistOptions = "-epmd_module epmd_client -start_epmd false",
    CmdLine = lists:concat([DistOptions, ExtraArgs]),
    % Options
    Options = #{auto_connect => false, connect_all => false, cmd_line => CmdLine,
        connection => {undefined, undefined},
        code_path => [filename:dirname(code:which(epmd_client))]},
    % return Pid of the node
    {ok, Peer} = local_node:start_link(SName, Options),
    Peer.

%%--------------------------------------------------------------------
%% TEST CASES

local() ->
    [{doc, "Cluster discovery: discover node_count pids providing spg service, one on a local host"}].

docker() ->
    [{doc, "Cluster discovery: docker-enabled cluster"}].

%% Stateless service test:
% (a) control node exports 'control' service (in spg scope)
% (b) child nodes export 'smoke' service (in spg scope), totaling to number of child nodes
% (c) child nodes discover 'control' service
% (d) control node discovers child services

local(Config) ->
    NodeCount = ?config(node_count, Config),
    DataPath = ?config(data_dir, Config),

    SysConfig = lists:concat([" -config ", filename:join(DataPath, "sys.config")]),

    % control node
    Control = start_local(control, SysConfig),

    % start N slave containers - either locally or in docker
    SlaveArg = SysConfig ++ " -kernel inet_dist_listen_max 65535",
    Nodes = [start_local(list_to_atom("node" ++ integer_to_list(Seq)), SlaveArg)
        || Seq <- lists:seq(1, NodeCount)],

    % start the app on remote node - for local test only
    ?assertMatch({ok, _SpgPid}, gen_node:rpc(Control, gen_server, start, [{local, spg}, spg, [spg], []])),
    % start the 'control' service on the control node
    ControlPid = gen_node:rpc(Control, erlang, spawn, [fun () -> receive after infinity -> ok end end]),
    % join control service to spg
    ok = gen_node:rpc(Control, spg, join, [control, ControlPid]),

    % start spg scope on the control node
    %  (non-local start that by default, app does it)
    [start_service(Peer) || Peer <- Nodes],

    % run everything through control node, via gen_node RPC
    Result = gen_node:rpc(Control, ?MODULE, smoke_control, [smoke, NodeCount]),
    % here 'Result' is a list of 'spg' processes states, try that
    SpgProcs = [ok || {state, spg, _, _} <- Result],

    % shut everything down
    [gen_node:stop(N) || N <- Nodes ++ [Control]],
    % now verify if all went well
    ?assertEqual(lists:duplicate(NodeCount, ok), SpgProcs).

start_service(Peer) ->
    % start spg app
    {ok, [spg]} = gen_node:rpc(Peer, application, ensure_all_started, [spg]),
    % locate 'control' service
    {ok, _Pid} = gen_node:rpc(Peer, gen_server, start, [stateless_service, {spg, control, 1, 5000}, []]),
    % locate 'service proc'
    ServicePid = gen_node:rpc(Peer, erlang, whereis, [spg]),
    % join service proc
    ok = gen_node:rpc(Peer, spg, join, [smoke, ServicePid]).

%% Actual testcase code here
smoke_control(TestCase, NodeCount) ->
    % wait for 'enough' services (on a control node)
    {ok, Pid} = stateless_service:start_link(spg, TestCase, NodeCount),
    % now wait for all other nodes to have "enough" services
    % they will reply with 'ok'
    Published = spg:get_members(spg, TestCase),
    %
    ?LOG_INFO("Found services: ~s:~s => ~120p", [spg, TestCase, Published]),
    % here we know that 'spg' processes have joined 'smoke' group
    Result = [sys:get_state(SpgService) || SpgService <- Published],
    % time to do the test (benchmark)
    gen_server:stop(Pid),
    % done, finishing, and returning 'ok' multiple times
    Result.

docker(Config) ->
    Image = ?config(image, Config),
    NodeCount = ?config(node_count, Config),

    % control node
    {ok, Control} = docker_node:start_link(control, Image,
        #{auto_connect => false, connect_all => false, host => "control"}),

    % need to wait until 'control' is started and listening, but for how long?
    timer:sleep(500),

    % start N services
    Nodes = [
        begin
            Name = list_to_atom("node" ++ integer_to_list(Seq)),
            {ok, Node} = docker_node:start_link(Name, Image,
                #{auto_connect => false, connect_all => false, link => "control"}),
            Node
        end
        || Seq <- lists:seq(1, NodeCount)],

    %% flush output
    flush_output(Control),

    % now wait until control server gets N services
    ExpectedStr = integer_to_list(NodeCount),
    Reply = wait_for_services(Control, lists:reverse(ExpectedStr)),

    % shut everything down
    [gen_node:stop(N) || N <- Nodes ++ [Control]],
    ?assertEqual(ExpectedStr, Reply).

flush_output(Control) ->
    case gen_node:read(Control, line) of
        empty ->
            ok;
        _ ->
            flush_output(Control)
    end.

wait_for_services(Control, ExpectedRev) ->
    ok = gen_node:write(Control, <<"length(spg:get_members(smoke)).\n">>),
    case get_response(Control, length(ExpectedRev)) of
        ExpectedRev ->
            lists:reverse(ExpectedRev);
        _ ->
            wait_for_services(Control, ExpectedRev)
    end.

get_response(Control, Len) ->
    case gen_node:read(Control, line) of
        empty ->
            timer:sleep(5),
            get_response(Control, Len);
        {value, Line} ->
            Rev = lists:reverse(binary_to_list(Line)),
            lists:sublist(Rev, 1, Len)
    end.

build(Config) ->
    DataDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    % copy files needed to build a container
    {ok, _} = file:copy(filename:join(DataDir, "Dockerfile"),
        filename:join(PrivDir, "Dockerfile")),
    {ok, _} = file:copy(filename:join(DataDir, "rebar.config.template"),
        filename:join(PrivDir, "rebar.config")),
    % copy config
    ok = file:make_dir(filename:join(PrivDir, "config")),
    copy_files(DataDir, filename:join(PrivDir, "config"), ["sys.config", "vm.args"]),
    % copy sources
    ok = file:make_dir(filename:join(PrivDir, "src")),
    CodeDir = code:lib_dir(spg, src),
    {ok, SrcFiles} = file:list_dir(CodeDir),
    copy_files(CodeDir, filename:join(PrivDir, "src"), SrcFiles),
    % replace one source...
    {ok, _} = file:copy(filename:join(DataDir, "test_sup.erl.template"),
        filename:join([PrivDir, "src", "spg_sup.erl"])),
    % now build an image
    Image = "spg",
    Res = os:cmd("docker build " ++ PrivDir ++ " -t " ++ Image ++ ":latest"),
    % check that it was "successfully tagged"
    Expected = "Successfully tagged spg:latest\n",
    Actual = lists:reverse(lists:sublist(lists:reverse(Res), 1, length(Expected))),
    if Expected == Actual -> Image; true -> ct:pal("Docker output: ~120p", [Res]), undefined end.

copy_files(From, To, Files) ->
    [{ok, _} = file:copy(filename:join(From, File), filename:join(To, File))
        || File <- Files].