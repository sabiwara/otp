%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2011-2023. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%%
-module(inet_tls_dist).

-export([childspecs/0]).
-export([listen/2, accept/1, accept_connection/5,
	 setup/5, close/1, select/1, address/0, is_node_name/1]).

%% Generalized dist API
-export([gen_listen/3, gen_accept/2, gen_accept_connection/6,
	 gen_setup/6, gen_close/2, gen_select/2, gen_address/1]).

-export([verify_client/3, cert_nodes/1]).

-export([dbg/0]). % Debug

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").
-include_lib("public_key/include/public_key.hrl").

-include("ssl_api.hrl").
-include("ssl_cipher.hrl").
-include("ssl_internal.hrl").
-include_lib("kernel/include/logger.hrl").

-define(PROTOCOL, tls).

%% -------------------------------------------------------------------------

childspecs() ->
    {ok, [{ssl_dist_sup,{ssl_dist_sup, start_link, []},
	   permanent, infinity, supervisor, [ssl_dist_sup]}]}.

select(Node) ->
    gen_select(inet_tcp, Node).

gen_select(Driver, Node) ->
    inet_tcp_dist:gen_select(Driver, Node).

%% ------------------------------------------------------------
%% Get the address family that this distribution uses
%% ------------------------------------------------------------
address() ->
    gen_address(inet_tcp).
gen_address(Driver) ->
    inet_tcp_dist:gen_address(Driver).

%% -------------------------------------------------------------------------

is_node_name(Node) ->
    dist_util:is_node_name(Node).

%% -------------------------------------------------------------------------

hs_data_inet_tcp(Driver, Socket) ->
    Family = Driver:family(),
    {ok, Peername} = inet:peername(Socket),
    (inet_tcp_dist:gen_hs_data(Driver, Socket))
    #hs_data{
      f_address =
          fun(_, Node) ->
                  {node, _, Host} = dist_util:split_node(Node),
                  #net_address{
                     address  = Peername,
                     host     = Host,
                     protocol = ?PROTOCOL,
                     family   = Family
                    }
          end}.

hs_data_ssl(Driver, #sslsocket{pid = [_, DistCtrl|_]} = SslSocket) ->
    Family = Driver:family(),
    {ok, Peername} = ssl:peername(SslSocket),
    #hs_data{
       socket = DistCtrl,
       f_send =
           fun (_Ctrl, Packet) ->
                   f_send(SslSocket, Packet)
           end,
       f_recv =
           fun (_, Length, Timeout) ->
                   f_recv(SslSocket, Length, Timeout)
           end,
       f_setopts_pre_nodeup =
           fun (Ctrl) when Ctrl == DistCtrl ->
                   f_setopts_pre_nodeup(SslSocket)
           end,
       f_setopts_post_nodeup =
           fun (Ctrl) when Ctrl == DistCtrl ->
%%%                   sys:trace(Ctrl, true),
                   f_setopts_post_nodeup(SslSocket)
           end,
       f_getll =
           fun (Ctrl) when Ctrl == DistCtrl ->
                   f_getll(DistCtrl)
           end,
       f_address =
           fun (Ctrl, Node) when Ctrl == DistCtrl ->
                   f_address(Family, Peername, Node)
           end,
       mf_tick =
           fun (Ctrl) when Ctrl == DistCtrl ->
                   mf_tick(DistCtrl)
           end,
       mf_getstat =
           fun (Ctrl) when Ctrl == DistCtrl ->
                   mf_getstat(SslSocket)
           end,
       mf_setopts =
           fun (Ctrl, Opts) when Ctrl == DistCtrl ->
                   mf_setopts(SslSocket, Opts)
           end,
       mf_getopts =
           fun (Ctrl, Opts) when Ctrl == DistCtrl ->
                   mf_getopts(SslSocket, Opts)
           end,
       f_handshake_complete =
           fun (Ctrl, Node, DHandle) when Ctrl == DistCtrl ->
                   f_handshake_complete(DistCtrl, Node, DHandle)
           end}.

f_send(SslSocket, Packet) ->
    ssl:send(SslSocket, Packet).

f_recv(SslSocket, Length, Timeout) ->
    case ssl:recv(SslSocket, Length, Timeout) of
        {ok, Bin} when is_binary(Bin) ->
            {ok, binary_to_list(Bin)};
        Other ->
            Other
    end.

f_setopts_pre_nodeup(_SslSocket) ->
    ok.

f_setopts_post_nodeup(SslSocket) ->
    ssl:setopts(SslSocket, [inet_tcp_dist:nodelay()]).

f_getll(DistCtrl) ->
    {ok, DistCtrl}.

f_address(Family, Address, Node) ->
    case dist_util:split_node(Node) of
        {node,_,Host} ->
            #net_address{
               address=Address, host=Host,
               protocol=?PROTOCOL, family=Family};
        _ ->
            {error, no_node}
    end.

mf_tick(DistCtrl) ->
    DistCtrl ! tick,
    ok.

mf_getstat(SslSocket) ->
    case ssl:getstat(
           SslSocket, [recv_cnt, send_cnt, send_pend]) of
        {ok, Stat} ->
            split_stat(Stat,0,0,0);
        Error ->
            Error
    end.

mf_setopts(SslSocket, Opts) ->
    case setopts_filter(Opts) of
        [] ->
            ssl:setopts(SslSocket, Opts);
        Opts1 ->
            {error, {badopts,Opts1}}
    end.

mf_getopts(SslSocket, Opts) ->
    ssl:getopts(SslSocket, Opts).

f_handshake_complete(DistCtrl, Node, DHandle) ->
    tls_sender:dist_handshake_complete(DistCtrl, Node, DHandle).

setopts_filter(Opts) ->
    [Opt || {K,_} = Opt <- Opts,
            K =:= active orelse K =:= deliver orelse K =:= packet].

split_stat([{recv_cnt, R}|Stat], _, W, P) ->
    split_stat(Stat, R, W, P);
split_stat([{send_cnt, W}|Stat], R, _, P) ->
    split_stat(Stat, R, W, P);
split_stat([{send_pend, P}|Stat], R, W, _) ->
    split_stat(Stat, R, W, P);
split_stat([], R, W, P) ->
    {ok, R, W, P}.

%% -------------------------------------------------------------------------

listen(Name, Host) ->
    gen_listen(inet_tcp, Name, Host).

gen_listen(Driver, Name, Host) ->
    case inet_tcp_dist:gen_listen(Driver, Name, Host) of
        {ok, {Socket, Address, Creation}} ->
            inet:setopts(Socket, [{packet, 4}, {nodelay, true}]),
            {ok, {Socket, Address#net_address{protocol=?PROTOCOL}, Creation}};
        Other ->
            Other
    end.

%% -------------------------------------------------------------------------

accept(Listen) ->
    gen_accept(inet_tcp, Listen).

gen_accept(Driver, Listen) ->
    Kernel = self(),
    monitor_pid(
      spawn_opt(
        fun () ->
            process_flag(trap_exit, true),
            LOpts = application:get_env(kernel, inet_dist_listen_options, []),
            MaxPending =
                case lists:keyfind(backlog, 1, LOpts) of
                    {backlog, Backlog} -> Backlog;
                    false -> 128
                end,
            DLK = {Driver, Listen, Kernel},
            accept_loop(DLK, spawn_accept(DLK), MaxPending, #{})
        end,
        [link, {priority, max}])).

%% Concurrent accept loop will spawn a new HandshakePid when
%%  there is no HandshakePid already running, and Pending map is
%%  smaller than MaxPending
accept_loop(DLK, undefined, MaxPending, Pending) when map_size(Pending) < MaxPending ->
    accept_loop(DLK, spawn_accept(DLK), MaxPending, Pending);
accept_loop({_, _, NetKernelPid} = DLK, HandshakePid, MaxPending, Pending) ->
    receive
        {continue, HandshakePid} when is_pid(HandshakePid) ->
            accept_loop(DLK, undefined, MaxPending, Pending#{HandshakePid => true});
        {'EXIT', Pid, Reason} when is_map_key(Pid, Pending) ->
            Reason =/= normal andalso
                ?LOG_ERROR("TLS distribution handshake failed: ~p~n", [Reason]),
            accept_loop(DLK, HandshakePid, MaxPending, maps:remove(Pid, Pending));
        {'EXIT', HandshakePid, Reason} when is_pid(HandshakePid) ->
            %% HandshakePid crashed before turning into Pending, which means
            %%  error happened in accept. Need to restart the listener.
            exit(Reason);
        {'EXIT', NetKernelPid, Reason} ->
            %% Since we're trapping exits, need to manually propagate this signal
            exit(Reason);
        Unexpected ->
            ?LOG_WARNING("TLS distribution: unexpected message: ~p~n" ,[Unexpected]),
            accept_loop(DLK, HandshakePid, MaxPending, Pending)
    end.

spawn_accept({Driver, Listen, Kernel}) ->
    AcceptLoop = self(),
    spawn_link(
        fun () ->
            case Driver:accept(Listen) of
                {ok, Socket} ->
                    AcceptLoop ! {continue, self()},
                    case check_ip(Driver, Socket) of
                        true ->
                            accept_one(Driver, Kernel, Socket);
                        {false,IP} ->
                            ?LOG_ERROR(
                                "** Connection attempt from "
                                "disallowed IP ~w ** ~n", [IP]),
                            trace({disallowed, IP})
                    end;
                Error ->
                    exit(Error)
            end
        end).

accept_one(Driver, Kernel, Socket) ->
    Opts = setup_verify_client(Socket, get_ssl_options(server)),
    KTLS = proplists:get_value(ktls, Opts, false),
    case
        ssl:handshake(
          Socket,
          trace([{active, false},{packet, 4}|Opts]),
          net_kernel:connecttime())
    of
        {ok, #sslsocket{pid = [Receiver, Sender| _]} = SslSocket} ->
            case KTLS of
                true ->
                    {ok, KtlsInfo} = ssl_gen_statem:ktls_handover(Receiver),
                    case set_ktls(KtlsInfo) of
                        ok ->
                            accept_one(
                              Driver, Kernel, Socket,
                              fun inet_tcp:controlling_process/2, Socket);
                        {error, KtlsReason} ->
                            ?LOG_ERROR(
                               [{slogan, set_ktls_failed},
                                {reason, KtlsReason},
                                {pid, self()}]),
                            gen_tcp:close(Socket),
                            trace({ktls_error, KtlsReason})
                    end;
                false ->
                    accept_one(
                      Driver, Kernel, Sender,
                      fun ssl:controlling_process/2, SslSocket)
            end;
        {error, {options, _}} = Error ->
            %% Bad options: that's probably our fault.
            %% Let's log that.
            ?LOG_ERROR(
              "Cannot accept TLS distribution connection: ~s~n",
              [ssl:format_error(Error)]),
            gen_tcp:close(Socket),
            trace(Error);
        Other ->
            gen_tcp:close(Socket),
            trace(Other)
    end.
%%
accept_one(Driver, Kernel, DistCtrl, ControllingProcessFun, DistSocket) ->
    trace(Kernel ! {accept, self(), DistCtrl, Driver:family(), ?PROTOCOL}),
    receive
        {Kernel, controller, Pid} ->
            case ControllingProcessFun(DistSocket, Pid) of
                ok ->
                    trace(Pid ! {self(), controller});
                {error, Reason} ->
                    trace(Pid ! {self(), exit}),
                    ?LOG_ERROR(
                       [{slogan, controlling_process_failed},
                        {reason, Reason},
                        {pid, self()}])
            end;
        {Kernel, unsupported_protocol} ->
            trace(unsupported_protocol)
    end.


%% {verify_fun,{fun ?MODULE:verify_client/3,_}} is used
%% as a configuration marker that verify_client/3 shall be used.
%%
%% Replace the State in the first occurrence of
%% {verify_fun,{fun ?MODULE:verify_client/3,State}}
%% and remove the rest.
%% The inserted state is not accessible from a configuration file
%% since it is dynamic and connection dependent.
%%
setup_verify_client(Socket, Opts) ->
    setup_verify_client(Socket, Opts, true, []).
%%
setup_verify_client(_Socket, [], _, OptsR) ->
    lists:reverse(OptsR);
setup_verify_client(Socket, [Opt|Opts], First, OptsR) ->
    case Opt of
        {verify_fun,{Fun,_}} ->
            case Fun =:= fun ?MODULE:verify_client/3 of
                true ->
                    if
                        First ->
                            case inet:peername(Socket) of
                                {ok,{PeerIP,_Port}} ->
                                    {ok,Allowed} = net_kernel:allowed(),
                                    AllowedHosts = allowed_hosts(Allowed),
                                    setup_verify_client(
                                      Socket, Opts, false,
                                      [{verify_fun,
                                        {Fun, {AllowedHosts,PeerIP}}}
                                       |OptsR]);
                                {error,Reason} ->
                                    exit(trace({no_peername,Reason}))
                            end;
                        true ->
                            setup_verify_client(
                              Socket, Opts, First, OptsR)
                    end;
                false ->
                    setup_verify_client(
                      Socket, Opts, First, [Opt|OptsR])
            end;
        _ ->
            setup_verify_client(Socket, Opts, First, [Opt|OptsR])
    end.

allowed_hosts(Allowed) ->
    lists:usort(allowed_node_hosts(Allowed)).
%%
allowed_node_hosts([]) -> [];
allowed_node_hosts([Node|Allowed]) ->
    case dist_util:split_node(Node) of
        {node,_,Host} ->
            [Host|allowed_node_hosts(Allowed)];
        {host,Host} ->
            [Host|allowed_node_hosts(Allowed)];
        _ ->
            allowed_node_hosts(Allowed)
    end.

%% Same as verify_peer but check cert host names for
%% peer IP address
verify_client(_, {bad_cert,_} = Reason, _) ->
    {fail,Reason};
verify_client(_, {extension,_}, S) ->
    {unknown,S};
verify_client(_, valid, S) ->
    {valid,S};
verify_client(_, valid_peer, {[],_} = S) ->
    %% Allow all hosts
    {valid,S};
verify_client(PeerCert, valid_peer, {AllowedHosts,PeerIP} = S) ->
    case
        public_key:pkix_verify_hostname(
          PeerCert,
          [{ip,PeerIP}|[{dns_id,Host} || Host <- AllowedHosts]])
    of
        true ->
            {valid,S};
        false ->
            {fail,cert_no_hostname_nor_ip_match}
    end.


%% -------------------------------------------------------------------------

accept_connection(AcceptPid, DistCtrl, MyNode, Allowed, SetupTime) ->
    gen_accept_connection(
      inet_tcp, AcceptPid, DistCtrl, MyNode, Allowed, SetupTime).

gen_accept_connection(
  Driver, AcceptPid, DistCtrl, MyNode, Allowed, SetupTime) ->
    Kernel = self(),
    monitor_pid(
      spawn_opt(
        fun() ->
                do_accept(
                  Driver, AcceptPid, DistCtrl,
                  MyNode, Allowed, SetupTime, Kernel)
        end,
        dist_util:net_ticker_spawn_options())).

do_accept(
  Driver, AcceptPid, DistCtrl, MyNode, Allowed, SetupTime, Kernel) ->
    MRef = erlang:monitor(process, AcceptPid),
    receive
	{AcceptPid, controller} ->
            erlang:demonitor(MRef, [flush]),
            Timer = dist_util:start_timer(SetupTime),
            {HSData0, NewAllowed} =
                case is_port(DistCtrl) of
                    true ->
                        {hs_data_inet_tcp(Driver, DistCtrl),
                         Allowed};
                    false ->
                        {ok, SslSocket} = tls_sender:dist_tls_socket(DistCtrl),
                        link(DistCtrl),
                        {hs_data_ssl(Driver, SslSocket),
                         allowed_nodes(SslSocket, Allowed)}
                end,
            HSData =
                HSData0#hs_data{
                  kernel_pid = Kernel,
                  this_node = MyNode,
                  timer = Timer,
                  this_flags = 0,
                  allowed = NewAllowed},
            dist_util:handshake_other_started(trace(HSData));
        {AcceptPid, exit} ->
            %% this can happen when connection was initiated, but dropped
            %%  between TLS handshake completion and dist handshake start
            ?shutdown2(MyNode, connection_setup_failed);
        {'DOWN', MRef, _, _, _Reason} ->
            %% this may happen when connection was initiated, but dropped
            %% due to crash propagated from other handshake process which
            %% failed on inet_tcp:accept (see GH-5332)
            ?shutdown2(MyNode, connection_setup_failed)
    end.

allowed_nodes(_SslSocket, []) ->
    %% Allow all
    [];
allowed_nodes(SslSocket, Allowed) ->
    case ssl:peercert(SslSocket) of
        {ok,PeerCertDER} ->
            case ssl:peername(SslSocket) of
                {ok,{PeerIP,_Port}} ->
                    PeerCert =
                        public_key:pkix_decode_cert(PeerCertDER, otp),
                    case
                        allowed_nodes(
                          PeerCert, allowed_hosts(Allowed), PeerIP)
                    of
                        [] ->
                            ?LOG_ERROR(
                              "** Connection attempt from "
                              "disallowed node(s) ~p ** ~n", [PeerIP]),
                            ?shutdown2(
                               PeerIP, trace({is_allowed, not_allowed}));
                        AllowedNodes ->
                            AllowedNodes
                    end;
                Error1 ->
                    ?shutdown2(no_peer_ip, trace(Error1))
            end;
        {error,no_peercert} ->
            Allowed;
        Error2 ->
            ?shutdown2(no_peer_cert, trace(Error2))
    end.

allowed_nodes(PeerCert, [], PeerIP) ->
    case public_key:pkix_verify_hostname(PeerCert, [{ip,PeerIP}]) of
        true ->
            Host = inet:ntoa(PeerIP),
            true = is_list(Host),
            [Host];
        false ->
            []
    end;
allowed_nodes(PeerCert, [Node|Allowed], PeerIP) ->
    case dist_util:split_node(Node) of
        {node,_,Host} ->
            allowed_nodes(PeerCert, Allowed, PeerIP, Node, Host);
        {host,Host} ->
            allowed_nodes(PeerCert, Allowed, PeerIP, Node, Host);
        _ ->
            allowed_nodes(PeerCert, Allowed, PeerIP)
    end.

allowed_nodes(PeerCert, Allowed, PeerIP, Node, Host) ->
    case public_key:pkix_verify_hostname(PeerCert, [{dns_id,Host}]) of
        true ->
            [Node|allowed_nodes(PeerCert, Allowed, PeerIP)];
        false ->
            allowed_nodes(PeerCert, Allowed, PeerIP)
    end.

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    gen_setup(inet_tcp, Node, Type, MyNode, LongOrShortNames, SetupTime).

gen_setup(Driver, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    Kernel = self(),
    monitor_pid(
      spawn_opt(setup_fun(Driver, Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime),
                dist_util:net_ticker_spawn_options())).

-spec setup_fun(_,_,_,_,_,_,_) -> fun(() -> no_return()).
setup_fun(Driver, Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    fun() ->
            do_setup(
              Driver, Kernel, Node, Type,
              MyNode, LongOrShortNames, SetupTime)
    end.


-spec do_setup(_,_,_,_,_,_,_) -> no_return().
do_setup(Driver, Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    {Name, Address} = split_node(Driver, Node, LongOrShortNames),
    ErlEpmd = net_kernel:epmd_module(),
    {ARMod, ARFun} = get_address_resolver(ErlEpmd, Driver),
    Timer = trace(dist_util:start_timer(SetupTime)),
    case ARMod:ARFun(Name,Address,Driver:family()) of
    {ok, Ip, TcpPort, Version} ->
        do_setup_connect(Driver, Kernel, Node, Address, Ip, TcpPort, Version, Type, MyNode, Timer);
	{ok, Ip} ->
	    case ErlEpmd:port_please(Name, Ip) of
		{port, TcpPort, Version} ->
                do_setup_connect(Driver, Kernel, Node, Address, Ip, TcpPort, Version, Type, MyNode, Timer);
		Other ->
		    ?shutdown2(
                       Node,
                       trace(
                         {port_please_failed, ErlEpmd, Name, Ip, Other}))
	    end;
	Other ->
	    ?shutdown2(
               Node,
               trace({getaddr_failed, Driver, Address, Other}))
    end.

-spec do_setup_connect(_,_,_,_,_,_,_,_,_,_) -> no_return().

do_setup_connect(Driver, Kernel, Node, Address, Ip, TcpPort, Version, Type, MyNode, Timer) ->
    Opts =  trace(connect_options(get_ssl_options(client))),
    KTLS = proplists:get_value(ktls, Opts, false),
    dist_util:reset_timer(Timer),
    case ssl:connect(
        Ip, TcpPort,
        [binary, {active, false}, {packet, 4},
         {server_name_indication, Address},
            Driver:family(), {nodelay, true}] ++ Opts,
        net_kernel:connecttime()
    ) of
        {ok, #sslsocket{pid = [Receiver, Sender| _]} = SslSocket} ->
            HSData =
                case KTLS of
                    true ->
                        {ok, KtlsInfo} =
                            ssl_gen_statem:ktls_handover(Receiver),
                        case set_ktls(KtlsInfo) of
                            ok ->
                                #{socket := Socket} = KtlsInfo,
                                hs_data_inet_tcp(Driver, Socket);
                            {error, KtlsReason} ->
                                ?shutdown2(
                                   Node,
                                   trace({set_ktls_failed, KtlsReason}))
                        end;
                    false ->
                        _ = monitor_pid(Sender),
                        ok = ssl:controlling_process(SslSocket, self()),
                        link(Sender),
                        hs_data_ssl(Driver, SslSocket)
                end
                #hs_data{
                  kernel_pid = Kernel,
                  other_node = Node,
                  this_node = MyNode,
                  timer = Timer,
                  this_flags = 0,
                  other_version = Version,
                  request_type = Type},
            dist_util:handshake_we_started(trace(HSData));
        Other ->
        %% Other Node may have closed since
        %% port_please !
            ?shutdown2(
                Node,
                trace({ssl_connect_failed, Ip, TcpPort, Other}))
    end.

close(Socket) ->
    gen_close(inet, Socket).

gen_close(Driver, Socket) ->
    trace(Driver:close(Socket)).


%% ------------------------------------------------------------
%% Determine if EPMD module supports address resolving. Default
%% is to use inet_tcp:getaddr/2.
%% ------------------------------------------------------------
get_address_resolver(EpmdModule, _Driver) ->
    case erlang:function_exported(EpmdModule, address_please, 3) of
        true -> {EpmdModule, address_please};
        _    -> {erl_epmd, address_please}
    end.

%% ------------------------------------------------------------
%% Do only accept new connection attempts from nodes at our
%% own LAN, if the check_ip environment parameter is true.
%% ------------------------------------------------------------
check_ip(Driver, Socket) ->
    case application:get_env(check_ip) of
	{ok, true} ->
	    case get_ifs(Socket) of
		{ok, IFs, IP} ->
		    check_ip(Driver, IFs, IP);
		Other ->
		    ?shutdown2(
                       no_node, trace({check_ip_failed, Socket, Other}))
	    end;
	_ ->
	    true
    end.

check_ip(Driver, [{OwnIP, _, Netmask}|IFs], PeerIP) ->
    case {Driver:mask(Netmask, PeerIP), Driver:mask(Netmask, OwnIP)} of
	{M, M} -> true;
	_      -> check_ip(IFs, PeerIP)
    end;
check_ip(_Driver, [], PeerIP) ->
    {false, PeerIP}.

get_ifs(Socket) ->
    case inet:peername(Socket) of
	{ok, {IP, _}} ->
            %% XXX this is seriously broken for IPv6
	    case inet:getif(Socket) of
		{ok, IFs} -> {ok, IFs, IP};
		Error     -> Error
	    end;
	Error ->
	    Error
    end.


%% Look in Extensions, in all subjectAltName:s
%% to find node names in this certificate.
%% Host names are picked up as a subjectAltName containing
%% a dNSName, and the first subjectAltName containing
%% a commonName is the node name.
%%
cert_nodes(
  #'OTPCertificate'{
     tbsCertificate = #'OTPTBSCertificate'{extensions = Extensions}}) ->
    parse_extensions(Extensions).


parse_extensions(Extensions) when is_list(Extensions) ->
    parse_extensions(Extensions, [], []);
parse_extensions(asn1_NOVALUE) ->
    undefined. % Allow all nodes
%%
parse_extensions([], [], []) ->
    undefined; % Allow all nodes
parse_extensions([], Hosts, []) ->
    lists:reverse(Hosts);
parse_extensions([], [], Names) ->
    [Name ++ "@" || Name <- lists:reverse(Names)];
parse_extensions([], Hosts, Names) ->
    [Name ++ "@" ++ Host ||
        Host <- lists:reverse(Hosts),
        Name <- lists:reverse(Names)];
parse_extensions(
  [#'Extension'{
      extnID = ?'id-ce-subjectAltName',
      extnValue = AltNames}
   |Extensions],
  Hosts, Names) ->
    case parse_subject_altname(AltNames) of
        none ->
            parse_extensions(Extensions, Hosts, Names);
        {host,Host} ->
            parse_extensions(Extensions, [Host|Hosts], Names);
        {name,Name} ->
            parse_extensions(Extensions, Hosts, [Name|Names])
    end;
parse_extensions([_|Extensions], Hosts, Names) ->
    parse_extensions(Extensions, Hosts, Names).

parse_subject_altname([]) ->
    none;
parse_subject_altname([{dNSName,Host}|_AltNames]) ->
    {host,Host};
parse_subject_altname(
  [{directoryName,{rdnSequence,[Rdn|_]}}|AltNames]) ->
    %%
    %% XXX Why is rdnSequence a sequence?
    %% Should we parse all members?
    %%
    case parse_rdn(Rdn) of
        none ->
            parse_subject_altname(AltNames);
        Name ->
            {name,Name}
    end;
parse_subject_altname([_|AltNames]) ->
    parse_subject_altname(AltNames).


parse_rdn([]) ->
    none;
parse_rdn(
  [#'AttributeTypeAndValue'{
     type = ?'id-at-commonName',
     value = {utf8String,CommonName}}|_]) ->
    unicode:characters_to_list(CommonName);
parse_rdn([_|Rdn]) ->
    parse_rdn(Rdn).


%% If Node is illegal terminate the connection setup!!
split_node(Driver, Node, LongOrShortNames) ->
    case dist_util:split_node(Node) of
        {node, Name, Host} ->
	    check_node(Driver, Node, Name, Host, LongOrShortNames);
	{host, _} ->
	    ?LOG_ERROR(
              "** Nodename ~p illegal, no '@' character **~n",
              [Node]),
	    ?shutdown2(Node, trace({illegal_node_n@me, Node}));
	_ ->
	    ?LOG_ERROR(
              "** Nodename ~p illegal **~n", [Node]),
	    ?shutdown2(Node, trace({illegal_node_name, Node}))
    end.

check_node(Driver, Node, Name, Host, LongOrShortNames) ->
    case string:split(Host, ".", all) of
	[_] when LongOrShortNames =:= longnames ->
	    case Driver:parse_address(Host) of
		{ok, _} ->
		    {Name, Host};
		_ ->
		    ?LOG_ERROR(
                      "** System running to use "
                      "fully qualified hostnames **~n"
                      "** Hostname ~s is illegal **~n",
                      [Host]),
		    ?shutdown2(Node, trace({not_longnames, Host}))
	    end;
	[_,_|_] when LongOrShortNames =:= shortnames ->
	    ?LOG_ERROR(
              "** System NOT running to use "
              "fully qualified hostnames **~n"
              "** Hostname ~s is illegal **~n",
              [Host]),
	    ?shutdown2(Node, trace({not_shortnames, Host}));
	_ ->
	    {Name, Host}
    end.

%% -------------------------------------------------------------------------

connect_options(Opts) ->
    case application:get_env(kernel, inet_dist_connect_options) of
	{ok,ConnectOpts} ->
	    lists:ukeysort(1, ConnectOpts ++ Opts);
	_ ->
	    Opts
    end.

get_ssl_options(Type) ->
    try ets:lookup(ssl_dist_opts, Type) of
        [{Type, Opts0}] ->
            [{erl_dist, true} | dist_defaults(Opts0)];
        _ ->
            get_ssl_dist_arguments(Type)
    catch
        error:badarg ->
            get_ssl_dist_arguments(Type)
    end.

get_ssl_dist_arguments(Type) ->
    case init:get_argument(ssl_dist_opt) of
	{ok, Args} ->
	    [{erl_dist, true} | dist_defaults(ssl_options(Type, lists:append(Args)))];
	_ ->
	    [{erl_dist, true}]
    end.

dist_defaults(Opts) ->
    case proplists:get_value(versions, Opts, undefined) of
        undefined ->
            [{versions, ['tlsv1.2']} | Opts];
        _ ->
            Opts
    end.

ssl_options(_Type, []) ->
    [];
ssl_options(client, ["client_" ++ Opt, Value | T] = Opts) ->
    ssl_options(client, T, Opts, Opt, Value);
ssl_options(server, ["server_" ++ Opt, Value | T] = Opts) ->
    ssl_options(server, T, Opts, Opt, Value);
ssl_options(Type, [_Opt, _Value | T]) ->
    ssl_options(Type, T).
%%
ssl_options(Type, T, Opts, Opt, Value) ->
    case ssl_option(Type, Opt) of
        error ->
            error(malformed_ssl_dist_opt, [Type, Opts]);
        Fun ->
            [{list_to_atom(Opt), Fun(Value)}|ssl_options(Type, T)]
    end.

ssl_option(server, Opt) ->
    case Opt of
        "dhfile" -> fun listify/1;
        "fail_if_no_peer_cert" -> fun atomize/1;
        _ -> ssl_option(client, Opt)
    end;
ssl_option(client, Opt) ->
    case Opt of
        "certfile" -> fun listify/1;
        "cacertfile" -> fun listify/1;
        "keyfile" -> fun listify/1;
        "password" -> fun listify/1;
        "verify" -> fun atomize/1;
        "verify_fun" -> fun verify_fun/1;
        "crl_check" -> fun atomize/1;
        "crl_cache" -> fun termify/1;
        "reuse_sessions" -> fun atomize/1;
        "secure_renegotiate" -> fun atomize/1;
        "depth" -> fun erlang:list_to_integer/1;
        "hibernate_after" -> fun erlang:list_to_integer/1;
        "ciphers" ->
            %% Allows just one cipher, for now (could be , separated)
            fun (Val) -> [listify(Val)] end;
        "versions" ->
            %% Allows just one version, for now (could be , separated)
            fun (Val) -> [atomize(Val)] end;
        "ktls" -> fun atomize/1;
        _ -> error
    end.

listify(List) when is_list(List) ->
    List.

atomize(List) when is_list(List) ->
    list_to_atom(List);
atomize(Atom) when is_atom(Atom) ->
    Atom.

termify(String) when is_list(String) ->
    {ok, Tokens, _} = erl_scan:string(String ++ "."),
    {ok, Term} = erl_parse:parse_term(Tokens),
    Term.

verify_fun(Value) ->
    case termify(Value) of
	{Mod, Func, State} when is_atom(Mod), is_atom(Func) ->
	    Fun = fun Mod:Func/3,
	    {Fun, State};
	_ ->
	    error(malformed_ssl_dist_opt, [Value])
    end.

set_ktls(KtlsInfo) ->
    %%
    %% Check OS type and version
    %%
    case {os:type(), os:version()} of
        {{unix,linux}, {Major,Minor,_}}
          when 5 == Major, 2 =< Minor;
               5 < Major ->
            set_ktls_1(KtlsInfo);
        OsTypeVersion ->
            {error, {ktls_invalid_os, OsTypeVersion}}
    end.

%% Check TLS version and cipher suite
%%
set_ktls_1(
  #{tls_version := {3,4}, % 'tlsv1.3'
    cipher_suite := CipherSuite,
    socket := Socket} = KtlsInfo)
  when CipherSuite =:= ?TLS_AES_256_GCM_SHA384 ->
    %%
    %% See https://www.kernel.org/doc/html/latest/networking/tls.html
    %% and include/netinet/tcp.h
    %%
    SOL_TCP = 6,
    TCP_ULP = 31,
    KtlsMod = <<"tls">>, % Linux kernel module name
    KtlsModSize = byte_size(KtlsMod),
    _ = inet:setopts(Socket, [{raw, SOL_TCP, TCP_ULP, KtlsMod}]),
    %%
    %% Check if kernel module loaded,
    %% i.e if getopts SOL_TCP,TCP_ULP returns KtlsMod
    %%
    case
        inet:getopts(Socket, [{raw, SOL_TCP, TCP_ULP, KtlsModSize + 1}])
    of
        {ok, [{raw, SOL_TCP, TCP_ULP, <<KtlsMod:KtlsModSize/binary,0>>}]} ->
            set_ktls_2(KtlsInfo, Socket);
        Other ->
            {error, {ktls_not_supported, Other}}
    end;
set_ktls_1(
  #{tls_version := TLSVersion,
    cipher_suite := CipherSuite,
    socket := _}) ->
    {error, {ktls_invalid_cipher, TLSVersion, CipherSuite}}.

%% Set kTLS cipher
%%
set_ktls_2(
  #{write_state :=
        #cipher_state{
           key = <<WriteKey:32/bytes>>,
           iv = <<WriteSalt:4/bytes, WriteIV:8/bytes>>
          },
    write_seq := WriteSeq,
    read_state :=
        #cipher_state{
           key = <<ReadKey:32/bytes>>,
           iv = <<ReadSalt:4/bytes, ReadIV:8/bytes>>
          },
    read_seq := ReadSeq,
    socket_options := SocketOptions},
  Socket) ->
    %%
    %% See include/linux/tls.h
    %%
    TLS_1_3_VERSION_MAJOR = 3,
    TLS_1_3_VERSION_MINOR = 4,
    TLS_1_3_VERSION =
        (TLS_1_3_VERSION_MAJOR bsl 8) bor TLS_1_3_VERSION_MINOR,
    TLS_CIPHER_AES_GCM_256 = 52,
    TLS_crypto_info_TX =
        <<TLS_1_3_VERSION:16/native,
          TLS_CIPHER_AES_GCM_256:16/native,
          WriteIV/bytes, WriteKey/bytes,
          WriteSalt/bytes, WriteSeq:64/native>>,
    TLS_crypto_info_RX =
        <<TLS_1_3_VERSION:16/native,
          TLS_CIPHER_AES_GCM_256:16/native,
          ReadIV/bytes, ReadKey/bytes,
          ReadSalt/bytes, ReadSeq:64/native>>,
    SOL_TLS = 282,
    TLS_TX = 1,
    TLS_RX = 2,
    RawOptTX = {raw, SOL_TLS, TLS_TX, TLS_crypto_info_TX},
    RawOptRX = {raw, SOL_TLS, TLS_RX, TLS_crypto_info_RX},
    _ = inet:setopts(Socket, [RawOptTX]),
    _ = inet:setopts(Socket, [RawOptRX]),
    %%
    %% Check if cipher could be set
    %%
    case
        inet:getopts(
          Socket, [{raw, SOL_TLS, TLS_TX, byte_size(TLS_crypto_info_TX)}])
    of
        {ok, [RawOptTX]} ->
            #socket_options{
               mode = _Mode,
               packet = Packet,
               packet_size = PacketSize,
               header = Header,
               active = Active
              } = SocketOptions,
            case
                inet:setopts(
                  Socket,
                  [list, {packet, Packet}, {packet_size, PacketSize},
                   {header, Header}, {active, Active}])
            of
                ok -> ok;
                {error, SetoptError} ->
                    {error, {ktls_setopt_failed, SetoptError}}
            end;
        Other ->
            {error, {ktls_set_cipher_failed, Other}}
    end.

%% -------------------------------------------------------------------------

%% Trace point
trace(Term) -> Term.

%% Keep an eye on distribution Pid:s we know of
monitor_pid(Pid) ->
    %%spawn(
    %%  fun () ->
    %%          MRef = erlang:monitor(process, Pid),
    %%          receive
    %%              {'DOWN', MRef, _, _, normal} ->
    %%                  ?LOG_ERROR(
    %%                    [{slogan, dist_proc_died},
    %%                     {reason, normal},
    %%                     {pid, Pid}]);
    %%              {'DOWN', MRef, _, _, Reason} ->
    %%                  ?LOG_NOTICE(
    %%                    [{slogan, dist_proc_died},
    %%                     {reason, Reason},
    %%                     {pid, Pid}])
    %%          end
    %%  end),
    Pid.

dbg() ->
    dbg:stop(),
    dbg:tracer(),
    dbg:p(all, c),
    dbg:tpl(?MODULE, cx),
    dbg:tpl(erlang, dist_ctrl_get_data_notification, cx),
    dbg:tpl(erlang, dist_ctrl_get_data, cx),
    dbg:tpl(erlang, dist_ctrl_put_data, cx),
    ok.
