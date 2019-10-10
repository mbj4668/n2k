%%% Original code by Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% Modified by Martin Björklund

%%% TODO:
%%%  o  {<field-name>, <field-value>} ->
%%%     {<field-name>, {<field-value>, <units> | <enum-name> | [<bit-name>]}}
%%%         ... and use resolution to give proper field-value.
%%%   - still todo: bits + units
%%%                 also, some proprietary enums are more dynamic,
%%%                   e.g. for 126720.
%%%  o  handle reserverd values for int fields ("unknown")
%%%     see printNumber in analyzer.c
%%%  o  the decoding of some strings need to be more dynamic,
%%%     b/c they have variable length (see e.g. PGN 129285).
%%%  o  in order to handle last field variable length, do that already
%%%     in pgns.term; find that and do {length, 'variable'}.
%%%  o  handle type bcd (decimal encoded number) ??
%%%  o  126208 not handled, see below
%%%  o  better handling of the different int types


-module(gen_n2k_pgn).

-export([gen/1]).

gen([PgnsTermFile, ErlFile]) ->
    case file:consult(PgnsTermFile) of
        {ok, Def} ->
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
    case file:open(File, [write]) of
        {ok, Fd} ->
            try
                ok = write_header(Fd, InFile),
                ok = write_functions(Fd, Def)
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
    ModName = n2k_pgn, % FIXME
    io:format(Fd, "%% -*- erlang -*-\n", []),
    io:format(Fd, "%% Generated by ~p from ~s\n\n", [?MODULE, InFile]),
    io:format(Fd, "-module(~p).\n", [ModName]),
    io:format(Fd, "-export([is_fast/1]).\n", []),
    io:format(Fd, "-export([decode/2]).\n", []),
    io:format(Fd, "\n\n", []).

write_functions(Fd, Ps) ->
    Ls = [{PGN,proplists:get_value(length,Fs,8)} || {PGN,Fs} <- Ps],
    Ls1 = lists:usort(Ls),
    Ls2 = group_length(Ls1),
    Ls3 = [{P, lists:max(Ln)} || {P,Ln} <- Ls2],
    write_is_fast(Fd, Ls3, Ps),
    io:format(Fd, "\n\n", []),
    Enums = get_enums(Ps),
    write_enums(Fd, lists:usort(Enums)),
    io:format(Fd, "\n\n", []),
    write_decode(Fd, Ps).

group_length([{P,L}|Ls]) ->
    group_length(Ls, P, [L], []).

group_length([{P,L}|Ps], P, Ls, Acc) ->
    group_length(Ps, P, [L|Ls], Acc);
group_length([{Q,L}|Ps], P, Ls, Acc) ->
    group_length(Ps, Q, [L], [{P,Ls}|Acc]);
group_length([], P, Ls, Acc) ->
    [{P,Ls}|Acc].

%% generate the is_fast function
write_is_fast(Fd, [PGNL], Ps) ->
    emit_is_fast_(Fd, PGNL, ".", Ps);
write_is_fast(Fd, [PGNL|T], Ps) ->
    emit_is_fast_(Fd, PGNL, ";", Ps),
    write_is_fast(Fd, T, Ps).

emit_is_fast_(Fd, {PGN,Length}, Term, Ps) ->
    {PGN,Fs} = lists:keyfind(PGN, 1, Ps),
    Repeating = proplists:get_value(repeating_fields, Fs, 0),
    io:format(Fd, "is_fast(~p) -> ~w~s\n",
              [PGN,(Length > 8) orelse (Repeating =/= 0),Term]).

get_enums([{PGN, Info} | T]) ->
    PGNId = proplists:get_value(id, Info),
    get_fields_enums(proplists:get_value(fields,Info,[]), PGN, PGNId, T);
get_enums([]) ->
    [].

get_fields_enums([F|Fs], PGN, PGNId, T) ->
    case proplists:get_value(enums, F) of
        undefined ->
            get_fields_enums(Fs, PGN, PGNId, T);
        Enums ->
            [{PGN, PGNId, proplists:get_value(id, F), Enums} |
             get_fields_enums(Fs, PGN, PGNId, T)]
    end;
get_fields_enums([], _PGN, _PGNId, T) ->
    get_enums(T).

%% generate the enum function
write_enums(Fd, [{PGN, PGNId, EnumId, Enums}]) ->
    emit_enums(Fd, PGN, PGNId, EnumId, Enums, ".");
write_enums(Fd, [{PGN, PGNId, EnumId, Enums} | T]) ->
    emit_enums(Fd, PGN, PGNId, EnumId, Enums, ";"),
    write_enums(Fd, T).

emit_enums(Fd, PGN, PGNId, EnumId, Enums, Term) ->
    io:format(Fd, "enum(~p, ~s, ~s, Val) -> ~s~s\n",
              [PGN, maybe_quote(PGNId), maybe_quote(EnumId),
               format_enums(Enums), Term]).

format_enums(Enums) ->
    ["case Val of ",
     lists:map(fun({Enum, V}) ->
                       [integer_to_list(V), "->",
                        "<<\"", Enum, "\">>", $;]
               end, Enums),
     "_ -> undefined end"].

%% generate the decode function
%% FIXME! repeating field need extra function to parse tail!
write_decode(Fd, [{126208,_Info}|Ps]) ->
    %% FIXME: can't handle variable length yet
    write_decode(Fd, Ps);
write_decode(Fd, [{PGN,Info}|Ps]) ->
    write_decode(Fd, PGN, Info, ";"),
    write_decode(Fd, Ps);
write_decode(Fd, []) ->
    io:format(Fd, "decode(PGN,Data)->{unknown, [{pgn,PGN},{data,Data}]}.\n",
              []).

write_decode(Fd, PGN, Info, Term) ->
    Fs = proplists:get_value(fields,Info,[]),
    Repeating = proplists:get_value(repeating_fields,Info,0),
    ID = get_id(Info),
    {Fixed,Repeat} = lists:split(length(Fs)-Repeating, Fs),
    if
        Fixed  =:= [], Repeat =:= [] ->
            io:format(Fd, "decode(~p,<<_/bitstring>>) ->\n  {~s,[]}~s\n",
                      [PGN,
                       ID,
                       Term]);
        Fixed =:= [] ->
            {RepeatMatches, RepeatBindings, []} =
                format_fields(Repeat, PGN, pre),
            io:format(Fd, "decode(~p,<<_Repeat/bitstring>>) ->\n  {~s, "
                      "lists:append([ [~s] || <<~s>> <= _Repeat ~s])}~s\n",
                      [PGN,
                       ID,
                       catmap(fun format_binding/3,filter_reserved(Repeat),
                              {PGN, ID}, ","),
                       RepeatMatches,
                       RepeatBindings,
                       Term]);
        Repeat =:= [] ->
            {FixedMatches, FixedBindings, FixedGuards} =
                format_fields(Fixed, PGN, post),
%            io:format("fixed: ~p\n", [lists:last(Fixed)]),
%            io:format("xxxxx: ~p\n", [lists:last(FixedMatches)]),
            io:format(Fd, "decode(~p,<<~s,_/bitstring>>) ~s ->\n"
                          "~s {~s,[~s]}~s\n",
                      [PGN,
                       FixedMatches,
                       if FixedGuards == [] -> "";
                          true -> ["when ", FixedGuards]
                       end,
                       FixedBindings,
                       ID,
                       catmap(fun format_binding/3, filter_reserved(Fixed),
                              {PGN, ID}, ","),
                       Term]);
       true ->
            {FixedMatches, FixedBindings, FixedGuards} =
                format_fields(Fixed, PGN, post),
            {RepeatMatches, RepeatBindings, []} =
                format_fields(Repeat, PGN, pre),
            io:format(Fd, "decode(~p,<<~s,_Repeat/bitstring>>) ~s ->\n"
                      "~s {~s,[~s | "
                      "lists:append([ [~s] || <<~s>> <= _Repeat ~s])]}~s\n",
                      [PGN,
                       FixedMatches,
                       if FixedGuards == [] -> "";
                          true -> ["when ", FixedGuards]
                       end,
                       FixedBindings,
                       ID,
                       catmap(fun format_binding/3,filter_reserved(Fixed),
                              {PGN, ID}, ","),
                       catmap(fun format_binding/3,filter_reserved(Repeat),
                              {PGN, ID}, ","),
                       RepeatMatches,
                       RepeatBindings,
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
%% This is then optimized and flatten to:
%%
%% Matches:
%%  [{B1,6},{A,2}, {B2,8}, {B3,6},{C1,2}, {_,4},{D,2},{C2,2}, {E,16/little}]
%% Field variables:
%% [{B,20,[B3,B2,B1]}, {C,4,[C2,C1]}]}]
%%
%% If the PGN spec has a "match" field, we either match on it directly (if
%% it is a simple field), or create a guard for it.

format_fields(Fs, _PGN, PreOrPost) ->
    {Matches0, FVars0} = field_matches(Fs, 0, 0, [], [], []),
%    io:format("PGN ~p\n-------------\n~p\n~p\n",
%              [PGN, Matches0,
%               [{proplists:get_value(id, F), Vs} || {F, Vs} <- FVars0]]),
    {Matches1, FVars1} = replace_bytes(Matches0, FVars0, [], []),
%    io:format("PASS2\n~p\n~p\n",
%              [Matches1,
%               [{proplists:get_value(id, F), Vs} || {F, Vs} <- FVars1]]),
    {Matches2, FVars2} = replace_single_var(FVars1, Matches1, []),
    {FVarsGuards, FVars3} =
        lists:partition(fun({F, _}) -> is_matching_field(F) end, FVars2),
%    io:format("PASS3\n~p\n~p}\n\n",
%              [Matches2,
%               [{proplists:get_value(id, F), Vs} || {F, Vs} <- FVars2]]),
    {format_matches(Matches2),
     format_field_variables(FVars3, PreOrPost),
     format_guard_matches(FVarsGuards)}.

%% Loop over each field, handle all bits in one byte at the time.
%% CurBit is the next bit number to fill.
%% Matches :: [ByteMatch :: {Var, NBits}]
%% FVars :: [{Field, [{Var, NBits}]}]
field_matches([F | T], CurBit, N, ByteAcc, MatchesAcc, FVarsAcc) ->
    Size = proplists:get_value(length, F),
    field_matches0(F, T, Size, CurBit, N, [], ByteAcc, MatchesAcc, FVarsAcc);
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
              MatchesAcc, FVarsAcc) ->
    case can_replace_bytes(ByteMatches, Vars) of
        {true, ByteMatches0} ->
            replace_bytes(ByteMatches0, Fs,
                          [{matched, format_field(F, true)} | MatchesAcc],
                          FVarsAcc);
        false ->
            %% couldn't match this field. step forward in ByteMatches until
            %% we can start on a new byte, i.e, we need to skip until we
            %% find the last variable for this field.
            [ByteMatch | ByteMatches1] = ByteMatches,
            skip_until_var(lists:last(Vars), ByteMatch, ByteMatch,
                           ByteMatches1, Fs,
                           [{Var, 8} | MatchesAcc],
                           [{F, [{Var, 8} | Vars]} | FVarsAcc])
    end;
replace_bytes([ByteMatch | ByteMatches], [{F, Vars} | Fs],
              MatchesAcc, FVarsAcc) ->
    %% same as last clause above
    skip_until_var(lists:last(Vars), ByteMatch, ByteMatch,
                   ByteMatches, Fs, MatchesAcc, [{F, Vars} | FVarsAcc]);
replace_bytes([], _, MatchesAcc, FVarsAcc) ->
    {MatchesAcc, FVarsAcc}.

can_replace_bytes([[{Var, 8}] | ByteMatches], [{Var, 8} | Vars]) ->
    can_replace_bytes(ByteMatches, Vars);
can_replace_bytes(ByteMatches, []) ->
    {true, ByteMatches};
can_replace_bytes(_, _) ->
    false.

skip_until_var({Var, _}, [{Var, _} | T], ByteMatch, ByteMatches,
               Fs, MatchesAcc, FVarsAcc) ->
    case T of
        [] ->
            %% the last var of the field was also the last in the byte match,
            %% we can thus check a new byte.
            replace_bytes(ByteMatches, Fs,
                          lists:append(ByteMatch, MatchesAcc), FVarsAcc);
        _ ->
            %% we have found the variable for the field, but there are
            %% bits left in the byte match.  need to skip the fields that
            %% correspond to these bits.
            LastVarAndSz = lists:last(T),
            skip_until_field(LastVarAndSz, Fs, ByteMatches,
                             lists:append(ByteMatch, MatchesAcc), FVarsAcc)
    end;
skip_until_var(Var, [_ | T], ByteMatch, ByteMatches,
               Fs, MatchesAcc, FVarsAcc) ->
    skip_until_var(Var, T, ByteMatch, ByteMatches, Fs, MatchesAcc, FVarsAcc);
skip_until_var(Var, [], ByteMatch0, [ByteMatch | ByteMatches],
               Fs, MatchesAcc, FVarsAcc) ->
    skip_until_var(Var, ByteMatch, ByteMatch, ByteMatches, Fs,
                   lists:append(ByteMatch0, MatchesAcc), FVarsAcc).

skip_until_field(VarAndSz, [{_, Vars} = F | Fs], ByteMatches,
                 MatchesAcc, FVarsAcc) ->
    case member_and_rest(VarAndSz, Vars) of
        {true, []} ->
            replace_bytes(ByteMatches, Fs, MatchesAcc, [F | FVarsAcc]);
        {true, RestVars} ->
            [ByteMatch | ByteMatches1] = ByteMatches,
            skip_until_var(lists:last(RestVars), ByteMatch, ByteMatch,
                           ByteMatches1, Fs,
                           MatchesAcc, [F | FVarsAcc]);
        false ->
            skip_until_field(VarAndSz, Fs, ByteMatches,
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
replace_single_var([{F, [{Var, _}]} | Fs], Matches, FVarsAcc) ->
    case proplists:get_value(id, F) of
        "" ->
            replace_single_var(Fs, Matches, FVarsAcc);
        "reserved" ->
            replace_single_var(Fs, Matches, FVarsAcc);
        _ ->
            Matches1 =
                lists:keyreplace(Var, 1, Matches,
                                 {matched, format_field(F, true)}),
            replace_single_var(Fs, Matches1, FVarsAcc)
    end;
replace_single_var([FVar | Fs], Matches, FVarsAcc) ->
    replace_single_var(Fs, Matches, [FVar | FVarsAcc]);
replace_single_var([], Matches, FVarsAcc) ->
    {Matches, lists:reverse(FVarsAcc)}.

format_matches(Matches) ->
    catmap(fun({matched, Str}, _, _) ->
                   Str;
              ({Var, NBits}, _, _) ->
                   [Var, ":", integer_to_list(NBits)]
           end, Matches, [], ",").

format_field_variables([], _) ->
    "";
format_field_variables(FVars, PreOrPost) ->
    [if PreOrPost == pre -> ",";
        true -> ""
     end,
     catmap(fun({F, Vars}, _, _) ->
                    ["<<", format_field(F, false), ">> = <<",
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

format_field(F, DirectMatch) ->
    Var = case proplists:get_value(match,F) of
              undefined -> get_var(F);
              Match -> integer_to_list(Match)
          end,
    Size = proplists:get_value(length, F),
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
                  bits -> [Endian, "unsigned"];
                  bcd -> "bitstring";     %% interpret later
                  _string -> "bitstring"  %% interpret later
              end,
    [Var,":",integer_to_list(Size),"/",BitType].

%% filter reserved field not wanted in result list
filter_reserved(Fs) ->
    lists:foldr(fun(F,Acc) ->
                        case proplists:get_value(id,F) of
                            "reserved" -> Acc;
                            "" -> Acc;
                            _ -> [F|Acc]
                        end
                end, [], Fs).

format_binding(F,_Last,{PGN, PGNId}) ->
    case proplists:get_value(match,F) of
        undefined ->
            ID = get_id(F),
            Var = get_var(F),
            Units =
                case proplists:get_value(units,F) of
                    undefined ->
                        "undefined";
                    UnitsStr ->
                        io_lib:write_atom(list_to_atom(UnitsStr))
                end,
            case proplists:get_value(resolution,F) of
                undefined ->
                    case proplists:get_value(enums,F) of
                        undefined ->
                            case proplists:get_value(type,F) of
                                string_a ->
                                    ["{",ID,",n2k:decode_string_a(",
                                     Var,")}"];
                                _ ->
                                    ["{",ID,",",Var,",",Units,"}"]
                            end;
                        _Enums ->
                            ["{",ID,",",format_enum_var(PGN, PGNId,
                                                        ID, Var),"}"]
                    end;
                Resolution when is_integer(Resolution)->
                    ["{",ID,",",Var,"*",
                     integer_to_list(Resolution),",",Units,"}"];
                Resolution when is_float(Resolution)->
                    ["{",ID,",",Var,"*",
                     float_to_list(Resolution),",",Units,"}"]
            end;
        Match ->
            ID = get_id(F),
            ["{",ID,",",integer_to_list(Match),"}"]
    end.

format_enum_var(PGN, PGNId, ID, Var) ->
    ["{",Var,",enum(", integer_to_list(PGN), ",", PGNId, ",", ID, ",",
     Var,")}"].

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
    case proplists:get_value(id, F) of
        "" ->
            Order = proplists:get_value(order, F),
            "_"++integer_to_list(Order);
        "reserved" ->
            "_";
        ID ->
            varname(ID)
    end.

varname(Cs0=[C|Cs]) ->
    if C >= $a, C =< $z -> [string:to_upper(C)|Cs];
       C >= $A, C =< $Z -> Cs0;
       true -> [$_|Cs0]
    end.

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