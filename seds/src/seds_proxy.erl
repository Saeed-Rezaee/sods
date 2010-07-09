%% Copyright (c) 2010, Michael Santos <michael.santos@gmail.com>
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% Redistributions of source code must retain the above copyright
%% notice, this list of conditions and the following disclaimer.
%%
%% Redistributions in binary form must reproduce the above copyright
%% notice, this list of conditions and the following disclaimer in the
%% documentation and/or other materials provided with the distribution.
%%
%% Neither the name of the author nor the names of its contributors
%% may be used to endorse or promote products derived from this software
%% without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.
-module(seds_proxy).
-behaviour(gen_fsm).

-include_lib("kernel/src/inet_dns.hrl").
-include("seds.hrl").

-record(state, {
        dnsfd,          % dns server socket
        s,              % proxied socket

        sum = 0,        % number of bytes sent
        data = [<<>>]   % list of binaries: data returned by proxied server
    }).


-define(MAXDATA, 110).

% Interface
-export([send/5]).
-export([start_link/2]).
-export([label/1]).
% States
-export([proxy/2]).
% Behaviours
-export([init/1, handle_event/3, handle_sync_event/4,
        handle_info/3, terminate/3, code_change/4]).


%%--------------------------------------------------------------------
%%% Interface
%%--------------------------------------------------------------------
send(Pid, IP, Port, #dns_rec{} = Query, {up, Data}) when is_pid(Pid) ->
    gen_fsm:send_event(Pid, {dns_query, IP, Port, Query, Data});
send(Pid, IP, Port, #dns_rec{} = Query, {down, _}) when is_pid(Pid) ->
    gen_fsm:send_event(Pid, {dns_query, IP, Port, Query}).

%%--------------------------------------------------------------------
%%% Behaviours
%%--------------------------------------------------------------------
start_link(Socket, {ServerIP, ServerPort}) ->
    {ok, Pid} = gen_fsm:start(?MODULE, [
            Socket,
            {ServerIP, ServerPort}
        ], []),
    erlang:monitor(process, Pid),
    {ok, Pid}.

init([DNSSocket, {ServerIP, ServerPort}]) ->
    process_flag(trap_exit, true),
    {ok, Socket} = gen_tcp:connect(ServerIP, ServerPort, [
            binary,
            {packet, 0},
            {active, once}
        ]),
    error_logger:info_report([
            {proxy_forward, {ServerIP, ServerPort}},
            {socket, Socket}
        ]),
    {ok, proxy, #state{
            dnsfd = DNSSocket,
            s = Socket
        }}.


handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {next_state, StateName, State}.


%%
%% State: proxy
%%

% From server
handle_info({tcp, Socket, Data}, proxy, #state{s = Socket} = State) ->
    {next_state, proxy, State#state{
            data = [Data|State#state.data]
        }, ?PROXY_TIMEOUT};

% Connection closed
handle_info({tcp_closed, Socket}, proxy, #state{s = Socket} = State) ->
    {stop, shutdown, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.


%%--------------------------------------------------------------------
%%% States
%%--------------------------------------------------------------------
proxy({dns_query, IP, Port, #dns_rec{
            header = Header,
            qdlist = [#dns_query{
                    domain = Domain,
                    type = Type
                }|_]
        } = Rec, Data}, #state{
        sum = Sum,
        dnsfd = DNSSocket,
        s = Socket
    } = State) ->

    Payload = list_to_binary(base32:decode(string:to_upper(Data))),

    ok = gen_tcp:send(Socket, Payload),

    Sum1 = Sum + byte_size(Payload),

    Packet = inet_dns:encode(
        Rec#dns_rec{
            header = Header#dns_header{
                qr = true,
                ra = true
            },
            anlist = [#dns_rr{
                    domain = Domain,
                    type = Type,
                    data = seq(Sum1)
                }]
        }),

    error_logger:info_report([
            {direction, up},
            {dns_query, Rec},
            {data, Data},
            {base64, Payload},
            {packet, Packet}
        ]),

    ok = gen_udp:send(DNSSocket, IP, Port, Packet),
    {next_state, proxy, State, ?PROXY_TIMEOUT};
proxy({dns_query, IP, Port, #dns_rec{
            header = Header,
            qdlist = [#dns_query{
                    domain = Domain,
                    type = Type
                }|_]
        } = Rec}, #state{
        dnsfd = DNSSocket,
        s = Socket,
        data = Data
    } = State) ->

    % Client polled, allow more data from server
    ok = inet:setopts(Socket, [{active, once}]),

    {Payload, Rest} = data(Type, Data),

    Response = Rec#dns_rec{
            header = Header#dns_header{
                qr = true,
                ra = true
            },
            anlist = [#dns_rr{
                    domain = Domain,
                    type = Type,
                    data = Payload
                }]},

    Packet = inet_dns:encode(Response),

    error_logger:info_report([
            {direction, down},
            {dns_query, Rec},
            {data, Data},
            {payload, Payload},
            {response, Response},
            {packet, Packet}
        ]),

    ok = gen_udp:send(DNSSocket, IP, Port, Packet),

    {next_state, proxy, State#state{
            data = [Rest]
        }, ?PROXY_TIMEOUT};
proxy(timeout, State) ->
    {stop, timeout, State}.

%%--------------------------------------------------------------------
%%% Internal Functions
%%--------------------------------------------------------------------
seq(N) when is_integer(N) ->
    <<I1,I2,I3,I4>> = <<N:32>>,
    {I1,I2,I3,I4}.


data(_, [<<>>]) ->
    {[],<<>>};
data(Type, Data) when is_list(Data) ->
    data(Type, list_to_binary(lists:reverse(Data)));

% TXT records
data(txt, Data) ->
    case byte_size(Data) of
        N when N > ?MAXDATA * 2 ->
            <<D1:?MAXDATA/bytes, D2:?MAXDATA/bytes, Rest/binary>> = Data,
            {[base64:encode_to_string(D1), base64:encode_to_string(D2)], Rest};
        N when N > ?MAXDATA ->
            <<D1:?MAXDATA/bytes, Rest/binary>> = Data,
            {[base64:encode_to_string(D1)], Rest};
        _ ->
            {[base64:encode_to_string(Data)], <<>>}
    end;

% NULL records
data(null, Data) ->
    case byte_size(Data) of
        N when N > ?MAXDATA * 2 ->
            <<D1:(?MAXDATA*2)/bytes, Rest/binary>> = Data,
            {base64:encode(D1), Rest};
        _ ->
            {base64:encode(Data), <<>>}
    end;

% CNAME records
data(cname, Data) ->
    case byte_size(Data) of
        N when N > ?MAXDATA ->
            <<D1:?MAXDATA/bytes, Rest/binary>> = Data,
            {label(base32:encode(D1)), Rest};
        _ ->
            {label(base32:encode(Data)), <<>>}
    end.

label(String) when length(String) < ?MAXLABEL ->
    String;
label(String) ->
    re:replace(String, ".{63}", "&.", [global, {return, list}]).


