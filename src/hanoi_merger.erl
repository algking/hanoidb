%% ----------------------------------------------------------------------------
%%
%% hanoi: LSM-trees (Log-Structured Merge Trees) Indexed Storage
%%
%% Copyright 2011-2012 (c) Trifork A/S.  All Rights Reserved.
%% http://trifork.com/ info@trifork.com
%%
%% Copyright 2012 (c) Basho Technologies, Inc.  All Rights Reserved.
%% http://basho.com/ info@basho.com
%%
%% This file is provided to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
%% License for the specific language governing permissions and limitations
%% under the License.
%%
%% ----------------------------------------------------------------------------

-module(hanoi_merger).
-author('Kresten Krab Thorup <krab@trifork.com>').

%%
%% Merging two BTrees
%%

-export([merge/6]).

-include("hanoi.hrl").

%%
%% Most likely, there will be plenty of I/O being generated by
%% concurrent merges, so we default to running the entire merge
%% in one process.
%%
-define(LOCAL_WRITER, true).

merge(A,B,C, Size, IsLastLevel, Options) ->
    {ok, BT1} = hanoi_reader:open(A, [sequential|Options]),
    {ok, BT2} = hanoi_reader:open(B, [sequential|Options]),
    case ?LOCAL_WRITER of
        true ->
            {ok, Out} = hanoi_writer:init([C, [{size,Size} | Options]]);
        false ->
            {ok, Out} = hanoi_writer:open(C, [{size,Size} | Options])
    end,

    {node, AKVs} = hanoi_reader:first_node(BT1),
    {node, BKVs} = hanoi_reader:first_node(BT2),

    scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, 0, {0, none}).

terminate(Count, Out) ->

    case ?LOCAL_WRITER of
        true ->
            {stop, normal, ok, _} = hanoi_writer:handle_call(close, self(), Out);
        false ->
            ok = hanoi_writer:close(Out)
    end,

    {ok, Count}.

step(S) ->
    step(S, 1).

step({N, From}, Steps) ->
    {N-Steps, From}.

hibernate_scan(Keep) ->
    erlang:garbage_collect(),
    receive
        {step, From, HowMany} ->
            {BT1, BT2, OutBin, IsLastLevel, AKVs, BKVs, Count, N} = erlang:binary_to_term( zlib:gunzip( Keep ) ),
            scan(BT1, BT2, hanoi_writer:deserialize(OutBin), IsLastLevel, AKVs, BKVs, Count, {N+HowMany, From})
    end.

scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, {N, FromPID}) when N < 1, AKVs =/= [], BKVs =/= [] ->
    case FromPID of
        none ->
            ok;
        {PID, Ref} ->
            PID ! {Ref, step_done}
    end,

    receive
        {step, From, HowMany} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, {N+HowMany, From})
    after 10000 ->
            case ?LOCAL_WRITER of
                true ->
                    Args = {BT1, BT2, hanoi_writer:serialize(Out), IsLastLevel, AKVs, BKVs, Count, N},
                    Keep = zlib:gzip ( erlang:term_to_binary( Args ) ),
                    hibernate_scan(Keep);
                false ->
                    scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, {0, none})
            end
    end;

scan(BT1, BT2, Out, IsLastLevel, [], BKVs, Count, Step) ->
    case hanoi_reader:next_node(BT1) of
        {node, AKVs} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, Step);
        end_of_data ->
            hanoi_reader:close(BT1),
            scan_only(BT2, Out, IsLastLevel, BKVs, Count, Step)
    end;

scan(BT1, BT2, Out, IsLastLevel, AKVs, [], Count, Step) ->
    case hanoi_reader:next_node(BT2) of
        {node, BKVs} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Count, Step);
        end_of_data ->
            hanoi_reader:close(BT2),
            scan_only(BT1, Out, IsLastLevel, AKVs, Count, Step)
    end;

scan(BT1, BT2, Out, IsLastLevel, [{Key1,Value1}|AT]=AKVs, [{Key2,Value2}|BT]=BKVs, Count, Step) ->
    if Key1 < Key2 ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = hanoi_writer:handle_cast({add, Key1, Value1}, Out);
                false ->
                    ok = hanoi_writer:add(Out2=Out, Key1, Value1)
            end,

            scan(BT1, BT2, Out2, IsLastLevel, AT, BKVs, Count+1, step(Step));

       Key2 < Key1 ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = hanoi_writer:handle_cast({add, Key2, Value2}, Out);
                false ->
                    ok = hanoi_writer:add(Out2=Out, Key2, Value2)
            end,
            scan(BT1, BT2, Out2, IsLastLevel, AKVs, BT, Count+1, step(Step));

       %% cases below have Key1 == Key2, hence it consumes 2 elements

       (?TOMBSTONE =:= Value2) and (true =:= IsLastLevel) ->
            scan(BT1, BT2, Out, IsLastLevel, AT, BT, Count, step(Step, 2));

       true ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = hanoi_writer:handle_cast({add, Key2, Value2}, Out);
                false ->
                    ok = hanoi_writer:add(Out2=Out, Key2, Value2)
            end,
            scan(BT1, BT2, Out2, IsLastLevel, AT, BT, Count+1, step(Step, 2))
    end.

scan_only(BT, Out, IsLastLevel, KVs, Count, {N, FromPID}) when N < 1, KVs =/= [] ->
    case FromPID of
        none ->
            ok;
        {PID, Ref} ->
            PID ! {Ref, step_done}
    end,

    receive
        {step, From, HowMany} ->
            scan_only(BT, Out, IsLastLevel, KVs, Count, {N+HowMany, From})
    end;

scan_only(BT, Out, IsLastLevel, [], Count, {_, FromPID}=Step) ->
    case hanoi_reader:next_node(BT) of
        {node, KVs} ->
            scan_only(BT, Out, IsLastLevel, KVs, Count, Step);
        end_of_data ->
            case FromPID of
                none ->
                    ok;
                {PID, Ref} ->
                    PID ! {Ref, step_done}
            end,
            hanoi_reader:close(BT),
            terminate(Count, Out)
    end;

scan_only(BT, Out, true, [{_,?TOMBSTONE}|Rest], Count, Step) ->
    scan_only(BT, Out, true, Rest, Count, step(Step));

scan_only(BT, Out, IsLastLevel, [{Key,Value}|Rest], Count, Step) ->
    case ?LOCAL_WRITER of
        true ->
            {noreply, Out2} = hanoi_writer:handle_cast({add, Key, Value}, Out);
        false ->
            ok = hanoi_writer:add(Out2=Out, Key, Value)
    end,
    scan_only(BT, Out2, IsLastLevel, Rest, Count+1, step(Step)).
