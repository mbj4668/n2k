%%% Original code by Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% Heavily modified by Martin Björklund
%%%
%%% Used at compile time to generate Erlang code that can be
%%% used to decode NMEA messages into Erlang terms.
%%%
%%% TODO:
%%%  o  handle type bcd (decimal encoded number)
%%%  o  126208 not handled, see below
%%%  o  handle repeating fields

-module(gen_n2k_pgn).

-export([gen/1]).

gen([PgnsTermFile, ErlFile]) ->
    case file:consult(PgnsTermFile) of
        {ok, [Def]} ->
            case save(ErlFile, Def, PgnsTermFile) of
                ok ->
                    init:stop(0);
                Error ->
                    io:format("** ~p\n", [Error]),
                    init:stop(1)
            end;
        Error ->
            io:format("** ~p\n", [Error]),
            init:stop(1)
    end.

save(File, Def, InFile) ->
    case file:open(File, [write, {encoding, utf8}]) of
        {ok, Fd} ->
            try
                {PGNs, Enums1, Enums2, Bits1} = Def,
                ok = write_header(Fd, InFile),
                ok = write_enums1(Fd, Enums1),
                ok = write_enums2(Fd, Enums2),
                ok = write_bits1(Fd, Bits1),
                ok = write_pgn_functions(Fd, PGNs)
            catch
                error:Reason:Stacktrace ->
                    {error, {Reason, Stacktrace}}
            after
                file:close(Fd)
            end;
        Error ->
            Error
    end.

write_header(Fd, InFile) ->
    ModName = n2k_pgn,
    io:format(Fd, "%% -*- erlang -*-\n", []),
    io:format(Fd, "%% Generated by ~p from ~s\n\n", [?MODULE, InFile]),
    io:format(Fd, "-module(~p).\n", [ModName]),
    io:format(Fd, "-export([is_fast/1]).\n", []),
    io:format(Fd, "-export([decode/2]).\n", []),
    io:format(Fd, "-export([type_info/2]).\n", []),
    io:format(Fd, "-export([erlang_module/1]).\n", []),
    io:format(Fd, "\n\n", []),
    io:format(Fd, "chk_exception1(MaxVal, Val) ->\n", []),
    io:format(Fd, "    if Val == MaxVal ->\n", []),
    io:format(Fd, "            'Unknown';\n", []),
    io:format(Fd, "       true ->\n", []),
    io:format(Fd, "            Val\n", []),
    io:format(Fd, "    end.\n", []),
    io:format(Fd, "chk_exception2(MaxVal, Val) ->\n", []),
    io:format(Fd, "    if Val == MaxVal ->\n", []),
    io:format(Fd, "            'Unknown';\n", []),
    io:format(Fd, "       Val == (MaxVal - 1) ->\n", []),
    io:format(Fd, "            'Error';\n", []),
    io:format(Fd, "       true ->\n", []),
    io:format(Fd, "            Val\n", []),
    io:format(Fd, "    end.\n", []),
    io:format(Fd, "\n\n", []).

write_pgn_functions(Fd, Ps) ->
    write_is_fast(Fd, Ps),
    io:format(Fd, "\n\n", []),
    write_decode(Fd, Ps),
    io:format(Fd, "\n\n", []),
    write_type_info(Fd, Ps),
    io:format(Fd, "\n\n", []),
    write_erlang_module(Fd, Ps).

%% generate the is_fast function
write_is_fast(Fd, Ps) ->
    FastL = [PGN || {PGN, Fs} <- Ps,
                    fast == proplists:get_value(type, Fs)],
    %% single ranges
    io:format(
      Fd,
      "is_fast(PGN) when PGN =< 65535 -> false;\n",
      []),
    %% fast-packet propietary range, as defined by main N2k spec 3.4.1.2
    io:format(
      Fd,
      "is_fast(PGN) when 130816 =< PGN andalso PGN =< 131071 -> true;\n",
      []),
    %% mixed single/fast; only write the fast PGNs
    lists:foreach(
      fun(PGN) ->
              io:format(Fd, "is_fast(~p) -> true;\n", [PGN])
      end, lists:usort(FastL)),
    io:format(Fd, "is_fast(_) -> false.\n", []).

%% generate the decode function
%% FIXME! repeating field need extra function to parse tail!
write_decode(Fd, [{126208,_Info}|Ps]) ->
    %% TODO: In order to implement this PGN we would need a generated table
    %% of all PGNs and their fields.  For example
    %% `pgn_field(PGN, FieldNumber)`.
    write_decode(Fd, Ps);
write_decode(Fd, [{PGN,Info}|Ps]) ->
    write_decode(Fd, PGN, Info, ";"),
    write_decode(Fd, Ps);
write_decode(Fd, []) ->
    %% Add decode of the fallback PGNs
    io:format(Fd,
"decode(126720,
       <<_0:8,IndustryCode:3/little-unsigned,_2:2,_1:3,Data/bitstring>>)  ->
    <<ManufacturerCode:11/unsigned>> = <<_1:3,_0:8>>,
    {manufacturerProprietaryFastPacketAddressable,
     [{manufacturerCode,chk_exception2(2047,ManufacturerCode)},
      {industryCode,chk_exception1(7,IndustryCode)},
      {data,Data}]};
 decode(61184,
       <<_0:8,IndustryCode:3/little-unsigned,_2:2,_1:3,Data/bitstring>>)  ->
    <<ManufacturerCode:11/unsigned>> = <<_1:3,_0:8>>,
    {manufacturerProprietarySingleFrameAddressable,
     [{manufacturerCode,chk_exception2(2047,ManufacturerCode)},
      {industryCode,chk_exception1(7,IndustryCode)},
      {data,Data}]};
 decode(PGN,
       <<_0:8,IndustryCode:3/little-unsigned,_2:2,_1:3,Data/bitstring>>)
  when 65280 =< PGN andalso PGN =< 065535 ->
    <<ManufacturerCode:11/unsigned>> = <<_1:3,_0:8>>,
    {manufacturerProprietarySingleFrameGlobal,
     [{manufacturerCode,chk_exception2(2047,ManufacturerCode)},
      {industryCode,chk_exception1(7,IndustryCode)},
      {data,Data}]};
 decode(PGN,
       <<_0:8,IndustryCode:3/little-unsigned,_2:2,_1:3,Data/bitstring>>)
  when 130816 =< PGN andalso PGN =< 131071 ->
    <<ManufacturerCode:11/unsigned>> = <<_1:3,_0:8>>,
    {manufacturerProprietaryFastPacketGlobal,
     [{manufacturerCode,chk_exception2(2047,ManufacturerCode)},
      {industryCode,chk_exception1(7,IndustryCode)},
      {data,Data}]};
 decode(PGN,Data)->{unknown, [{pgn,PGN},{data,Data}]}.\n",
              []).

write_decode(Fd, PGN, Info, Term) ->
    Fs = proplists:get_value(fields,Info,[]),
    Repeating = proplists:get_value(repeating_fields,Info,0),
    ID = get_id(Info),
    {Fixed,Repeat} = lists:split(length(Fs)-Repeating, Fs),
    {PreDecode, PostDecode} =
        case proplists:get_value(erlang_module,Info, undefined) of
            undefined ->
                {"", ""};
            Mod ->
                {[Mod, ":decode("], ")"}
        end,
    if
        Fixed  =:= [], Repeat =:= [] ->
            io:format(Fd, "decode(~p,<<_/bitstring>>) ->\n  {~s,[]}~s\n",
                      [PGN,
                       ID,
                       Term]);
        Fixed =:= [] ->
            {RepeatMatches, RepeatBindings, []} =
                format_fields(Repeat, PGN, Fs, pre),
            io:format(Fd, "decode(~p,<<_Repeat/bitstring>>) ->\n  ~s{~s, "
                      "lists:append([ [~s] || <<~s>> <= _Repeat ~s])}~s~s\n",
                      [PGN,
                       PreDecode,
                       ID,
                       catmap(fun format_binding/3,filter_reserved(Repeat),
                              {PGN, ID}, ","),
                       RepeatMatches,
                       RepeatBindings,
                       PostDecode,
                       Term]);
        Repeat =:= [] ->
            {FixedMatches, FixedBindings, FixedGuards} =
                format_fields(Fixed, PGN, Fs, post),
            Trail =
                case proplists:get_value(id, lists:last(Fs)) of
                    "data" ->
                        "";
                    _ ->
                        ",_/bitstring"
                end,
            io:format(Fd, "decode(~p,<<~s"++Trail++">>) ~s ->\n"
                          "~s ~s{~s,[~s]}~s~s\n",
                      [PGN,
                       FixedMatches,
                       if FixedGuards == [] -> "";
                          true -> ["when ", FixedGuards]
                       end,
                       FixedBindings,
                       PreDecode,
                       ID,
                       catmap(fun format_binding/3, filter_reserved(Fixed),
                              {PGN, ID}, ","),
                       PostDecode,
                       Term]);
       true ->
            {FixedMatches, FixedBindings, FixedGuards} =
                format_fields(Fixed, PGN, Fs, post),
            {_RepeatMatches, _RepeatBindings, []} =
                format_fields(Repeat, PGN, Fs, pre),
            io:format(Fd, "decode(~p,<<~s,_Repeat/bitstring>>) ~s ->\n"
                      "~s ~s{~s,[~s | "
%% FIXME - the repeat handling code is not correct
%                      "lists:append([ [~s] || <<~s>> <= _Repeat ~s])]"
                      "[]]"
                      "}~s~s\n",
                      [PGN,
                       FixedMatches,
                       if FixedGuards == [] -> "";
                          true -> ["when ", FixedGuards]
                       end,
                       FixedBindings,
                       PreDecode,
                       ID,
                       catmap(fun format_binding/3,filter_reserved(Fixed),
                              {PGN, ID}, ","),
%                       catmap(fun format_binding/3,filter_reserved(Repeat),
%                              {PGN, ID}, ","),
%                       RepeatMatches,
%                       RepeatBindings,
                       PostDecode,
                       Term])
    end.


catmap(_Fun, [], _Arg, _Sep) ->
    [];
catmap(Fun, [F], Arg, _Sep) ->
    [Fun(F,true,Arg)];
catmap(Fun, [F|Fs], Arg, Sep) ->
    [Fun(F,false,Arg),Sep | catmap(Fun, Fs, Arg, Sep)].

%% For example, if the message has the following fields:
%%   A:  2 bits
%%   B: 20 bits
%%   C:  4 bits
%%   D:  6 bits
%%   E: 16 bits
%% then the bits are layed out like this (lsb):
%%
%% <<B1:6,A:2,  B2:8,  B3:6,C1:2,  D:6,C2:2, E1:8, E2:8>>,
%% <<B:20>> = <<B3:6, B2:8, B1:6>>
%% <<C:4>> = <<C2:2, C1:2>>
%%
%% From the field specs, we create a list of matches per byte.
%% Each match per byte is a tuple with a variable name and number of bits:
%% We also create a list of field names and the variables needed for that
%% field.  For example:
%%
%% Matches:
%%  [[{B1,6},{A1,2}], [{B2,8}], [{B3,6},{C1,2}],
%%   [{D1,6},{C2,2}], [{E1,8}], [{E2,8}]]
%% Field variables:
%%  [{A,2,[A1]}, {B,20,[B3,B2,B1]}, {C,4,[C2,C1]}, {D,2,[D1]}, {E,16,[E2,E1]}]
%%
%% This is then optimized and flattened to:
%%
%% Matches:
%%  [{B1,6},{A,2}, {B2,8}, {B3,6},{C1,2}, {_,4},{D,2},{C2,2}, {E,16/little}]
%% Field variables:
%% [{B,20,[B3,B2,B1]}, {C,4,[C2,C1]}]}]
%%
%% If the PGN spec has a "match" field, we either match on it directly (if
%% it is a simple field), or create a guard for it.

format_fields(Fs, _PGN, AllFs, PreOrPost) ->
    {Matches0, FVars0} = field_matches(Fs, 0, 0, [], [], []),
    {Matches1, FVars1} = replace_bytes(Matches0, FVars0, AllFs, [], []),
    {Matches2, FVars2} = replace_single_var(FVars1, Matches1, AllFs, []),
    Matches3 = strip_matches(Matches2, FVars2),
    {FVarsGuards, FVars3} =
        lists:partition(fun({F, _}) -> is_matching_field(F) end, FVars2),
    {format_matches(Matches3),
     format_field_variables(FVars3, AllFs, PreOrPost),
     format_guard_matches(FVarsGuards)}.

%% Loop over each field, handle all bits in one byte at the time.
%% CurBit is the next bit number to fill.
%% Matches :: [ByteMatch :: {Var, NBits}]
%% FVars :: [{Field, [{Var, NBits}]}]
field_matches([F | T], CurBit, N, ByteAcc, MatchesAcc, FVarsAcc) ->
    case proplists:get_value(length, F) of
        undefined ->
            case proplists:get_value(var_length, F) of
                true ->
                    VB = {var(N), -1},
                    field_matches(T, CurBit, N+1,
                                  ByteAcc,
                                  [[VB] | MatchesAcc],
                                  [{F, [VB]} | FVarsAcc])
            end;
        Size ->
            field_matches0(F, T, Size, CurBit, N, [],
                           ByteAcc, MatchesAcc, FVarsAcc)
    end;
field_matches([], CurBit, _N, ByteAcc, MatchesAcc, FVarsAcc) ->
    if CurBit > 0 andalso CurBit < 8 -> % fill with don't care
            Var = "_",
            VSize = 8 - CurBit,
            {[[{Var, VSize} | ByteAcc] | MatchesAcc], FVarsAcc};
       true ->
            ByteAcc = [], % assertion
            {MatchesAcc, FVarsAcc}
    end.

%% Create variables for all bits needed for the field, and keep track of
%% the variables created for the field.
field_matches0(F, T, Size, CurBit, N, Vars, ByteAcc, MatchesAcc, FVarsAcc) ->
    BitsLeft = 8 - CurBit,
    if CurBit == 8 ->
            %% we've filled up this byte, start a new
            field_matches0(F, T, Size, 0, N, Vars,
                           [], [ByteAcc | MatchesAcc], FVarsAcc);
       Size == 0 ->
            %% we're done with this field
            field_matches(T, CurBit, N,
                          ByteAcc, MatchesAcc, [{F, Vars} | FVarsAcc]);
       true ->
            Var = var(N),
            VSize =
                if Size =< BitsLeft -> % we fit in this byte
                        Size;
                   true -> % use all bits left
                        BitsLeft
                end,
            field_matches0(F, T, Size - VSize, CurBit + VSize, N+1,
                           [{Var, VSize} | Vars], [{Var, VSize} | ByteAcc],
                           MatchesAcc, FVarsAcc)
    end.

var(N) ->
    [$_ | integer_to_list(N)].

is_matching_field(F) ->
    proplists:get_value(match,F) /= undefined.

%% The input lists are reversed.  Find sequences of aligned bytes for
%% a single field, and replace with direct match of that field.
replace_bytes([[{Var, 8}] | ByteMatches], [{F, [{Var, 8} | Vars]} | Fs],
              AllFs, MatchesAcc, FVarsAcc) ->
    case can_replace_bytes(ByteMatches, Vars) of
        {true, ByteMatches0} ->
            replace_bytes(ByteMatches0, Fs, AllFs,
                          [{matched, format_field(F, true, AllFs)} |
                           MatchesAcc],
                          FVarsAcc);
        false ->
            %% couldn't match this field. step forward in ByteMatches until
            %% we can start on a new byte, i.e, we need to skip until we
            %% find the last variable for this field.
            [ByteMatch | ByteMatches1] = ByteMatches,
            skip_until_var(lists:last(Vars), ByteMatch, ByteMatch,
                           ByteMatches1, Fs, AllFs,
                           [{Var, 8} | MatchesAcc],
                           [{F, [{Var, 8} | Vars]} | FVarsAcc])
    end;
replace_bytes([ByteMatch | ByteMatches], [{F, Vars} | Fs],
              AllFs, MatchesAcc, FVarsAcc) ->
    %% same as last clause above
    skip_until_var(lists:last(Vars), ByteMatch, ByteMatch,
                   ByteMatches, Fs, AllFs, MatchesAcc, [{F, Vars} | FVarsAcc]);
replace_bytes([], _, _, MatchesAcc, FVarsAcc) ->
    {MatchesAcc, FVarsAcc}.

can_replace_bytes([[{Var, 8}] | ByteMatches], [{Var, 8} | Vars]) ->
    can_replace_bytes(ByteMatches, Vars);
can_replace_bytes(ByteMatches, []) ->
    {true, ByteMatches};
can_replace_bytes(_, _) ->
    false.

skip_until_var({Var, _}, [{Var, _} | T], ByteMatch, ByteMatches,
               Fs, AllFs, MatchesAcc, FVarsAcc) ->
    case T of
        [] ->
            %% the last var of the field was also the last in the byte match,
            %% we can thus check a new byte.
            replace_bytes(ByteMatches, Fs, AllFs,
                          lists:append(ByteMatch, MatchesAcc), FVarsAcc);
        _ ->
            %% we have found the variable for the field, but there are
            %% bits left in the byte match.  need to skip the fields that
            %% correspond to these bits.
            LastVarAndSz = lists:last(T),
            skip_until_field(LastVarAndSz, Fs, ByteMatches, AllFs,
                             lists:append(ByteMatch, MatchesAcc), FVarsAcc)
    end;
skip_until_var(Var, [_ | T], ByteMatch, ByteMatches,
               Fs, AllFs, MatchesAcc, FVarsAcc) ->
    skip_until_var(Var, T, ByteMatch, ByteMatches, Fs, AllFs,
                   MatchesAcc, FVarsAcc);
skip_until_var(Var, [], ByteMatch0, [ByteMatch | ByteMatches],
               Fs, AllFs, MatchesAcc, FVarsAcc) ->
    skip_until_var(Var, ByteMatch, ByteMatch, ByteMatches, Fs, AllFs,
                   lists:append(ByteMatch0, MatchesAcc), FVarsAcc).

skip_until_field(VarAndSz, [{_, Vars} = F | Fs], ByteMatches, AllFs,
                 MatchesAcc, FVarsAcc) ->
    case member_and_rest(VarAndSz, Vars) of
        {true, []} ->
            replace_bytes(ByteMatches, Fs, AllFs, MatchesAcc, [F | FVarsAcc]);
        {true, RestVars} ->
            [ByteMatch | ByteMatches1] = ByteMatches,
            skip_until_var(lists:last(RestVars), ByteMatch, ByteMatch,
                           ByteMatches1, Fs, AllFs,
                           MatchesAcc, [F | FVarsAcc]);
        false ->
            skip_until_field(VarAndSz, Fs, ByteMatches, AllFs,
                             MatchesAcc, [F | FVarsAcc])
    end.

member_and_rest(X, [X | T]) ->
    {true, T};
member_and_rest(X, [_ | T]) ->
    member_and_rest(X, T);
member_and_rest(_, []) ->
    false.

%% Replace a field with a single var with a direct match.
%% Skip reserved fields.
replace_single_var([{F, [{Var, _}]} | Fs], Matches, AllFs, FVarsAcc) ->
    case proplists:get_value(type, F) of
        reserved ->
            replace_single_var(Fs, Matches, AllFs, FVarsAcc);
        _ ->
            Matches1 =
                lists:keyreplace(Var, 1, Matches,
                                 {matched, format_field(F, true, AllFs)}),
            replace_single_var(Fs, Matches1, AllFs, FVarsAcc)
    end;
replace_single_var([FVar | Fs], Matches, AllFs, FVarsAcc) ->
    replace_single_var(Fs, Matches, AllFs, [FVar | FVarsAcc]);
replace_single_var([], Matches, _AllFs, FVarsAcc) ->
    {Matches, lists:reverse(FVarsAcc)}.

%% Remove spare / reserved fields at the end; we will match on _/bitstring
%% anyway.
strip_matches(Matches, FVars) ->
    RMatches = lists:reverse(Matches),
    strip_matches0(RMatches, FVars).

strip_matches0([{[$_ | _], _} = Vb | T] = L, FVars) ->
    case is_used(Vb, FVars) of
        false ->
            strip_matches0(T, FVars);
        true ->
            lists:reverse(L)
    end;
strip_matches0(L, _) ->
    lists:reverse(L).

is_used(Vb, FVars) ->
    lists:any(
      fun({_F, Vbs}) ->
              lists:member(Vb, Vbs)
      end, FVars).

format_matches(Matches) ->
    catmap(fun({matched, Str}, _, _) ->
                   Str;
              ({Var, NBits}, _, _) when is_integer(NBits) ->
                   [Var, ":", integer_to_list(NBits)];
              ({Var, NBitsVar}, _, _) ->
                   [Var, ":", NBitsVar]
           end, Matches, [], ",").

format_field_variables([], _, _) ->
    "";
format_field_variables(FVars, AllFs, PreOrPost) ->
    [if PreOrPost == pre -> ",";
        true -> ""
     end,
     catmap(fun({F, Vars}, _, _) ->
                    ["<<", format_field(F, false, AllFs), ">> = <<",
                     catmap(fun({Var, VSz}, _Last, _) ->
                                    [Var, ":", integer_to_list(VSz)]
                            end, Vars, [], ","),
                     ">>"]
            end, FVars, [], ","),
    if PreOrPost == post -> ",";
       true -> ""
    end].

format_guard_matches(FVars) ->
     catmap(
       fun({F, Vars}, _, _) ->
               MatchVal = integer_to_list(proplists:get_value(match, F)),
               Size = integer_to_list(proplists:get_value(length, F)),
               ["<<", MatchVal, ":", Size, ">> == <<",
                catmap(fun({Var, VSz}, _Last, _) ->
                               [Var, ":", integer_to_list(VSz)]
                       end, Vars, [], ","),
                ">>"]
       end, FVars, [], ",").

format_field(F, DirectMatch, AllFs) ->
    {Var, IsMatch} =
         case proplists:get_value(match,F) of
             undefined ->
                 {get_var(F), false};
             Match ->
                 {integer_to_list(Match), true}
         end,
    Id = proplists:get_value(id, F),
    Size =
        case proplists:get_value(length, F) of
            Len when is_integer(Len) ->
                integer_to_list(Len);
            undefined ->
                case proplists:get_value(bit_length_field, F) of
                    Fn when is_integer(Fn) ->
                        LenF = find_field(Fn, AllFs),
                        get_var(LenF);
                    undefined ->
                        case proplists:get_value(type, F) of
                            string_variable_short ->
                                -1;
                            string_variable_medium ->
                                -2
                        end
                end
        end,
    Signed = proplists:get_value(signed, F, false),
    Type   = proplists:get_value(type, F, int),
    Endian = if DirectMatch -> "little-";
                true -> ""
             end,
    BitType = case Type of
                  int -> if Signed -> [Endian, "signed"];
                            true -> [Endian, "unsigned"]
                         end;
                  float -> [Endian, "float"];
                  binary -> "bitstring";
                  enum -> [Endian, "unsigned"];
                  enum2 -> [Endian, "unsigned"];
                  bits -> [Endian, "unsigned"];
                  bcd -> "bitstring";     %% interpret later
                  _string -> "bitstring"  %% interpret later
              end,
    if Size == -1 ->
            [Var, "_L:8", ",", Var, ":(", Var, "_L-1)/binary"];
       Size == -2 ->
            [Var, "_L:16", ",", Var, ":(", Var, "_L-2)/binary"];
       IsMatch andalso BitType == "bitstring" ->
            [Var,":",Size];
       Id == "data" ->
            [Var,"/",BitType];
       true ->
            [Var,":",Size,"/",BitType]
    end.

find_field(N, [F | T]) ->
    case proplists:get_value(order, F) of
        N ->
            F;
        _ ->
            find_field(N, T)
    end.

%% filter reserved field not wanted in result list
filter_reserved(Fs) ->
    lists:foldr(fun(F,Acc) ->
                        case proplists:get_value(type,F) of
                            reserved -> Acc;
                            _ -> [F|Acc]
                        end
                end, [], Fs).

format_binding(F,_Last,_) ->
    case proplists:get_value(match,F) of
        undefined ->
            ID = get_id(F),
            Var = get_var(F),
            case proplists:get_value(type,F) of
                string_fixed ->
                    ["{",ID,",n2k:decode_string_fixed(",
                     Var,")}"];
                string_variable_short ->
                    ["{",ID,",n2k:decode_string_variable(",
                     Var,")}"];
                Type when Type == int;
                          Type == float;
                          Type == enum;
                          Type == enum2;
                          Type == bits;
                          Type == undefined ->
                    Length = proplists:get_value(length, F),
                    Signed = proplists:get_value(signed, F, false),
                    MaxVal =
                        if Signed ->
                                (1 bsl (Length-1)) - 1;
                           true ->
                                (1 bsl Length) - 1
                        end,
                    if Length == 1 ->
                            ["{",ID,",",Var,"}"];
                       Length =< 3 ->
                            ["{",ID,",chk_exception1(",
                             integer_to_list(MaxVal), ",",Var,")}"];
                       true ->
                            ["{",ID,",chk_exception2(",
                             integer_to_list(MaxVal), ",",Var,")}"]
                    end;
                _ ->
                    ["{",ID,",",Var,"}"]
            end;
        Match ->
            ID = get_id(F),
            ["{",ID,",",integer_to_list(Match),"}"]
    end.

%% works for both pgn info and fields
get_id(F) ->
    case proplists:get_value(id, F) of
        Cs0=[C|_] when C >= $a, C =< $z ->
            maybe_quote(Cs0);
        [C|Cs] when C >= $A, C =< $Z ->
            maybe_quote([string:to_lower(C)|Cs]);
        Cs when is_list(Cs) ->
            "'" ++ Cs ++ "'";
        undefined -> "unknown"
    end.

maybe_quote(String) ->
    [C | _] = String,
    case reserved_word(String) of
        false when C >= $a andalso C =< $z -> String;
        _ -> "'"++String++"'"
    end.

get_var(F) ->
    case proplists:get_value(type, F) of
        reserved ->
            "_";
        _ ->
            varname(proplists:get_value(id, F))
    end.

varname(Cs0=[C|Cs]) ->
    if C >= $a, C =< $z -> [string:to_upper(C)|Cs];
       C >= $A, C =< $Z -> Cs0;
       true -> [$_|Cs0]
    end.

write_type_info(Fd, Ps) ->
    Tab = ets:new(a, []),
    mk_type_info(Ps, Tab),
    L = ets:tab2list(Tab),
    write_type_info0(lists:sort(L), Fd).

mk_type_info([{_PGN, Info} | T], Tab) ->
    PGNId = proplists:get_value(id, Info),
    Fs = proplists:get_value(fields, Info, []),
    mk_type_info_fs(PGNId, Fs, Tab),
    mk_type_info(T, Tab);
mk_type_info([], _) ->
    ok.

mk_type_info_fs(PGNId, [[{order, _}, {id, IdStr} | T] | Fs], Tab) ->
    Id = list_to_atom(IdStr),
    case get_type(T) of
        {enum1, EnumName} ->
            ets:insert(Tab, {{PGNId, Id}, {enum1, EnumName}});
        {enum2, FieldId, EnumName} ->
            ets:insert(Tab, {{PGNId, Id}, {enum2, FieldId, EnumName}});
        {bit1, BitName} ->
            ets:insert(Tab, {{PGNId, Id}, {bit1, BitName}});
        {int, Resolution, Decimals, Unit} ->
            ets:insert(Tab, {{PGNId, Id},
                             {int, Resolution, Decimals, Unit}});
        {float, Unit} ->
            ets:insert(Tab, {{PGNId, Id}, {float, Unit}});
        _ ->
            ok
    end,
    mk_type_info_fs(PGNId, Fs, Tab);
mk_type_info_fs(_, [], _) ->
    ok.

get_type(Info) ->
    case
        {proplists:get_value(enum, Info),
         proplists:get_value(enum2, Info),
         proplists:get_value(bit, Info)}
    of
        {undefined, undefined, undefined} ->
            Unit = list_to_atom(proplists:get_value(unit, Info, "undefined")),
            Resolution = proplists:get_value(resolution, Info),
            Decimals =
                if Resolution /= undefined ->
                        round(math:log10(1/Resolution));
                   true ->
                        undefined
                end,
            case proplists:get_value(type, Info) of
                float ->
                    {float, Unit};
                int ->
                    Resolution1 =
                        if Resolution == undefined ->
                                1;
                           true ->
                                Resolution
                        end,
                    {int, Resolution1, Decimals, Unit};
                _ when Resolution /= undefined ->
                    {int, Resolution, Decimals, Unit};
                _ ->
                    undefined
            end;
        {EnumName, undefined, undefined} ->
            {enum1, EnumName};
        {undefined, Enum2Name, undefined} ->
            {enum2,
             list_to_atom(proplists:get_value(enum2_field, Info)),
             Enum2Name};
        {undefined, undefined, BitName} ->
            {bit1, BitName}
    end.

write_type_info0([{{PGNId, Id}, {enum1, EnumName}} | T], Fd) ->
    io:format(Fd, "type_info(~p,~p) -> {enums, enums1_~s()};\n",
              [list_to_atom(PGNId), Id, EnumName]),
    write_type_info0(T, Fd);
write_type_info0([{{PGNId, Id}, {enum2, FieldId, EnumName}} | T], Fd) ->
    io:format(Fd, "type_info(~p,~p) -> {enums, ~p, enums2_~s()};\n",
              [list_to_atom(PGNId), Id, FieldId, EnumName]),
    write_type_info0(T, Fd);
write_type_info0([{{PGNId, Id}, {bit1, BitName}} | T], Fd) ->
    io:format(Fd, "type_info(~p,~p) -> {bits, bits1_~s()};\n",
              [list_to_atom(PGNId), Id, BitName]),
    write_type_info0(T, Fd);
write_type_info0([{{PGNId, Id}, Type} | T], Fd) ->
    io:format(Fd, "type_info(~p,~p) -> ~9999p;\n",
              [list_to_atom(PGNId), Id, Type]),
    write_type_info0(T, Fd);
write_type_info0([], Fd) ->
    %% Add type_info for the fallback PGNs
    io:format(Fd,
"type_info(_,industryCode) ->
    {enums, enums1_INDUSTRY_CODE()};
 type_info(_,manufacturerCode) ->
    {enums, enums1_MANUFACTURER_CODE()};
 type_info(_,_) -> undefined.\n",
               []).

write_enums1(Fd, [{EnumName, Enums} | T]) ->
    io:format(Fd, "enums1_~s() ->\n    ~99999p.\n", [EnumName, Enums]),
    write_enums1(Fd, T);
write_enums1(_Fd, []) ->
    ok.

write_enums2(Fd, [{EnumName, Enums} | T]) ->
    io:format(Fd, "enums2_~s() ->\n    ~99999p.\n", [EnumName, Enums]),
    write_enums2(Fd, T);
write_enums2(_Fd, []) ->
    ok.

write_bits1(Fd, [{BitName, Bits} | T]) ->
    io:format(Fd, "bits1_~s() ->\n    ~99999p.\n", [BitName, Bits]),
    write_bits1(Fd, T);
write_bits1(_Fd, []) ->
    ok.


write_erlang_module(Fd, Ps) ->
    write_erlang_module0(Ps, Fd),
    io:format(Fd, "erlang_module(_) -> false.\n", []).

write_erlang_module0([{_PGN, Info} | T], Fd) ->
    case proplists:get_value(erlang_module,Info, undefined) of
        undefined ->
            ok;
        Mod ->
            PGNId = proplists:get_value(id, Info),
            io:format(Fd, "erlang_module(~s) -> {true, ~s};\n", [PGNId, Mod])
    end,
    write_erlang_module0(T, Fd);
write_erlang_module0([], _) ->
    ok.

reserved_word("after") -> true;
reserved_word("begin") -> true;
reserved_word("case") -> true;
reserved_word("try") -> true;
reserved_word("cond") -> true;
reserved_word("catch") -> true;
reserved_word("andalso") -> true;
reserved_word("orelse") -> true;
reserved_word("end") -> true;
reserved_word("fun") -> true;
reserved_word("if") -> true;
reserved_word("let") -> true;
reserved_word("of") -> true;
reserved_word("receive") -> true;
reserved_word("when") -> true;
reserved_word("bnot") -> true;
reserved_word("not") -> true;
reserved_word("div") -> true;
reserved_word("rem") -> true;
reserved_word("band") -> true;
reserved_word("and") -> true;
reserved_word("bor") -> true;
reserved_word("bxor") -> true;
reserved_word("bsl") -> true;
reserved_word("bsr") -> true;
reserved_word("or") -> true;
reserved_word("xor") -> true;
reserved_word(_) -> false.
