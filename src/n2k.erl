%%% Library functions for NMEA encoding / decoding and formatting.
-module(n2k).

-export([decode_nmea_init/0, decode_nmea/2, fmt_error/1]).
-export([fmt_nmea_message/1]).
-export([encode_canid/1, decode_canid/1]).
-export([decode_string_a/1, decode_string/2]).
-export([fmt_ms_time/1, fmt_date/1, fmt_hex/2]).
-export([encode_nmea_message/2, encode_nmea_message/3]).

-export_type([canid/0, frame/0, message/0, dec_error/0, dec_state/0]).

%% A CANID is a 29-bit number.  When decoded, it is a canid().
-type canid() ::
        {
          Pri :: integer() % 3 bits
        , PGN :: integer()
        , Src :: byte() % src device of message
        , Dst :: byte() % dst device of message, 16#ff means all
        }.

%% Represents one CAN frame, with additional meta data (time)
-type frame() ::
        {
          Time :: integer() % milliseconds
        , Id   :: canid()
        , Data :: binary() % 0-8 bytes
        }.

%% Represents one NMEA message, with additional meta data (time)
-type message() ::
        {
          Time :: integer() % milliseconds
        , Id   :: canid()
        , Data :: {PGNName :: atom()
                 , Fields :: [{FieldName :: atom(), Val :: term()}]}
        }.

-type dec_error() ::
        %% the (generated) pgn decode function failed to decode the
        %% message
        {pgn_decode_error, Src :: byte(), PGN :: integer()}
        %% a fast packet frame was received but the previous frame was
        %% not found
      | {frame_loss, Src :: byte(), PGN :: integer(), PrevIndex :: integer()}.

-opaque dec_state() :: map().

-spec decode_nmea_init() -> dec_state().
%%% Call this to get an initial decode state to pass to decode_nmea/2.
decode_nmea_init() ->
    #{}.

-spec decode_nmea(n2k:frame(), dec_state()) ->
          {true, n2k:message(), dec_state()}
        | {false, dec_state()}
        | {error, dec_error(), dec_state()}.
%% Call this repeatedly with frames and a decode state.
%% When a message has been assembled, {true, Message, State1} is
%% returned.
%% If the frame is part of a fast packet message, {false, State1} is
%% returned.
%% If there's an error, {error, DecError, State1} is returned.
decode_nmea(Frame, Map0) ->
    {Time, Id, Data} = Frame,
    {_Prio, PGN, Src, _Dst} = Id,
    case n2k_pgn:is_fast(PGN) of
        false ->
            Message = {Time, Id, n2k_pgn:decode(PGN, Data)},
            {true, Message, Map0};
        true ->
            case Data of
                <<Order:3,0:5,PLen,PayLoad/binary>> ->
                    %% this is the first of the fast messages, store
                    %% for assembly
                    P = {Order, _Index = 0, PLen-byte_size(PayLoad), [PayLoad]},
                    Map1 = maps:put({Src, PGN}, P, Map0),
                    {false, Map1};
                <<Order:3,Index:5,PayLoad/binary>> ->
                    PrevIndex = Index-1,
                    case maps:find({Src,PGN}, Map0) of
                        {ok, {Order, PrevIndex, PLen0, Data0}} ->
                            Data1 = [PayLoad | Data0],
                            case PLen0 - byte_size(PayLoad) of
                                PLen1 when PLen1 > 0 ->
                                    P = {Order, Index, PLen1, Data1},
                                    Map1 = maps:put({Src, PGN}, P, Map0),
                                    {false, Map1};
                                _ ->
                                    %% last frame
                                    Data2 =
                                        list_to_binary(lists:reverse(Data1)),
                                    Map1 = maps:remove({Src, PGN}, Map0),
                                    try
                                        Message = {Time, Id,
                                                   n2k_pgn:decode(PGN, Data2)},
                                        {true, Message, Map1}
                                    catch
                                        _:_X:Stacktrace ->
                                            io:format("** error: ~p ~p\n",
                                                      [_X, Stacktrace]),
                                            {error,
                                             {pgn_decode_error, Src, PGN}, Map0}
                                    end
                            end;
                        _ ->
                            {error, {frame_loss, Src, PGN, Order, PrevIndex},
                             Map0}
                    end
            end;
        unknown ->
            Message = {Time, Id,
                      {unknown, [{unknown, binary_to_list(Data)}]}},
            {true, Message, Map0}
    end.

-spec fmt_error(dec_error()) -> string().
fmt_error({frame_loss, Src, PGN, Order, PrevIndex}) ->
    io_lib:format("warning: pgn ~w:~w, order ~w, frame lost ~w\n",
                  [Src, PGN, Order, PrevIndex]);
fmt_error({pgn_decode_error, Src, PGN}) ->
    io_lib:format("warning: pgn ~w:~w, could not decode\n", [Src,PGN]).

-spec encode_canid(canid()) -> integer().
encode_canid({Pri,PGN,Src,Dst}) ->
    IDA = (PGN bsr 8) band 16#ff,
    if IDA < 240 ->
            <<ID:29>> = <<Pri:3,0:1,(PGN bsr 8):9,Dst:8,Src:8>>,
            ID;
       true ->
            <<ID:29>> = <<Pri:3,0:1,PGN:17,Src:8>>,
            ID
    end.
%encode_canid({Pri,PGN,Src,16#ff}) ->
%    <<ID:29>> = <<Pri:3,0:1,PGN:17,Src:8>>,
%    ID;
%encode_canid({Pri,PGN,Src,Dst}) ->
%    <<ID:29>> = <<Pri:3,0:1,(PGN bsr 8):9,Dst:8,Src:8>>,
%    ID.

-spec decode_canid(integer()) -> canid().
decode_canid(CanId) ->
    case <<CanId:29>> of
        <<Pri:3,_:1,DP:1,IDA:8,Dst:8,Src:8>> when IDA < 240 ->
            PGN = (DP bsl 16) + (IDA bsl 8),
            {Pri,PGN,Src,Dst};
        <<Pri:3,_:1,PGN:17,Src:8>> ->
            {Pri,PGN,Src,16#ff}
    end.

decode_string_a(Bin) ->
    case binary:last(Bin) of
        0 ->
            %% remove all fill chars - can't use NUL in re:run :(
            %% we assume that 0 isn't used in the middle of the string...
            [Bin0 | _] = string:split(Bin, <<0>>),
            Bin0;
        Ch when Ch == 16#ff; Ch == $\s; Ch == $@ ->
            %% remove all fill chars
            {match, [{Pos, _End}]} = re:run(Bin, [Ch, $+, $$]),
            binary:part(Bin, 0, Pos);
        _ ->
            Bin
    end.

-define(CTRL_UNICODE, 0). % UTF-16
-define(CTRL_ASCII, 1). % actually, latin-1

%% string_lau is N2K type DF50
decode_string(string_lau, <<Len,?CTRL_ASCII,Str:Len/binary,Rest/binary>>) ->
    {Str, Rest};
decode_string(string_lau, <<Len,?CTRL_UNICODE,Str:Len/binary,Rest/binary>>) ->
    {unicode:characters_to_binary(Str, utf16, utf8), Rest};
%% string is unclear
decode_string(string, <<2,Bin/binary>>) ->
    %% the string ends with byte 0x01
    [Str, Rest] = binary:split(Bin, <<1>>),
    {Str, Rest};
decode_string(string, <<3,1,0,Rest/binary>>) ->
    %% empty string
    {<<>>, Rest};
decode_string(string, <<Len0,1,Bin/binary>>) when Len0 > 3 ->
    Len = Len0 - 2,
    <<Str:Len/binary,Rest/binary>> = Bin,
    {Str, Rest};
decode_string(string, <<_Unknown,Rest/binary>>) ->
    %% is this really correct?
    {<<>>, Rest};
%% string_lz is proprietary fusion for old PGNs
decode_string(string_lz, <<Len,Str:Len/binary,0,Rest/binary>>) ->
    {Str, Rest}.

%% encode a message into a list of frames.
%% encode_nmea_message/2 can only be used for fast PGNs
encode_nmea_message(CanId, Data) ->
    encode_nmea_message(CanId, Data, 0).
encode_nmea_message({_Pri, PGN, _Src, _Dst} = CanId, Data, Order) ->
    CanIdInt = encode_canid(CanId),
    case n2k_pgn:is_fast(PGN) of
        false ->
            [{CanIdInt, Data}];
        true ->
            mk_fast_frames(Order, CanIdInt, Data)
    end.

mk_fast_frames(Order, CanIdInt, Payload) ->
    PLen = byte_size(Payload),
    if PLen =< 6 ->
            [{CanIdInt, <<Order:3, 0:5, PLen, Payload/binary>>}];
       true ->
            Data = binary_part(Payload, 0, 6),
            [{CanIdInt, <<Order:3, 0:5, PLen, Data/binary>>} |
             mk_fast_frames(Order, 1, CanIdInt, 6, PLen, Payload)]
    end.

mk_fast_frames(Order, Index, CanIdInt, Pos, PLen, Payload) ->
    if (Pos+7) >= PLen ->
            %% last frame
            Data = binary_part(Payload, Pos, (PLen - Pos)),
            [{CanIdInt, <<Order:3, Index:5, Data/binary>>}];
        true ->
            Data = binary_part(Payload, Pos, 7),
            [{CanIdInt, <<Order:3, Index:5, Data/binary>>} |
             mk_fast_frames(Order, Index+1, CanIdInt, Pos+7, PLen, Payload)]
    end.


-spec fmt_nmea_message(message()) -> string().
fmt_nmea_message({Time, {Pri, PGN, Src, Dst}, {MsgName, Fields}}) ->
    Fs =
        try
            [fmt_field(MsgName, F, Fields) || F <- Fields]
        catch _:_X:S ->
                io:format("**ERROR: ~p\n~p\n", [_X, S]),
                [io_lib:format("** FIELDS: ~p", [Fields])]
        end,
    io_lib:format("~s ~w ~3w ~3w ~6w ~w: ~s\n",
                  [fmt_ms_time(Time), Pri, Src, Dst, PGN, MsgName,
                   string:join(Fs, "; ")]).

fmt_ms_time(Milliseconds) ->
    Ms = Milliseconds rem 1000,
    R0 = Milliseconds div 1000,
    Sec = R0 rem 60,
    R1 = R0 div 60,
    Min = R1 rem 60,
    R2 = R1 div 60,
    Hr = R2 rem 24,
    io_lib:format("~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0w",
                  [Hr, Min, Sec, Ms]).

fmt_date({Y,M,D}) ->
    io_lib:format("~4.4.0w-~2.2.0w-~2.2.0w",
                  [Y,M,D]).

fmt_hex(<<X>>, _) ->
    [hex(X bsr 4),hex(X)];
fmt_hex(<<X,Bin/binary>>, Separator) ->
    [hex(X bsr 4),hex(X),Separator | fmt_hex(Bin, Separator)].

hex(X) ->
    element((X band 15)+1, {$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,$A,$B,$C,$D,$E,$F}).

fmt_field(MsgName, {Name, Val}, Fields) ->
    [atom_to_list(Name), " = ", fmt_val(MsgName, Name, Val, Fields)].

fmt_val(_MsgName, _Name, Val, _Fields) when is_atom(Val) ->
    atom_to_list(Val);
fmt_val(MsgName, Name, Val, Fields) ->
    case n2k_pgn:type_info(MsgName, Name) of
        {int, Resolution, Decimals, Units} ->
            case Units of
                days ->
                    Date =
                        calendar:gregorian_days_to_date(
                          calendar:date_to_gregorian_days({1970,1,1}) + Val),
                    fmt_date(Date);
                rad ->
                    io_lib:format("~.1f deg",
                                  [Val*Resolution * 180 / math:pi()]);
                'rad/s' ->
                    io_lib:format("~.1f deg/s",
                                  [Val*Resolution * 180 / math:pi()]);
                _ when Decimals /= undefined, Decimals > 0 ->
                    [io_lib:format("~.*f", [Decimals, Val*Resolution]),
                     fmt_units(Units)];
                _ when Decimals /= undefined, Decimals < 0 ->
                    [io_lib:format("~p", [Val*Resolution]),
                     fmt_units(Units)];
                _ ->
                    [io_lib:format("~p", [Val]), fmt_units(Units)]
            end;
        {float, Units} ->
            [io_lib:format("~.5f", [Val]), fmt_units(Units)];
        {enums, Enums} ->
            case lists:keyfind(Val, 2, Enums) of
                {Str, _} ->
                    Str;
                _ ->
                    integer_to_list(Val)
            end;
        _ when Name == deviceFunction ->
            case proplists:get_value(deviceClass, Fields) of
                undefined ->
                    io_lib:format("~999p", [Val]);
                Class ->
                    n2k_pgn:device_function_name(Class, Val)
            end;
        _ ->
            case n2k_pgn:erlang_module(MsgName) of
                false ->
                    io_lib:format("~999p", [Val]);
                {true, Mod} ->
                    Mod:format_val(MsgName, Name, Val, Fields)
            end
    end.

fmt_units(undefined) ->
    "";
fmt_units(Units) ->
    [$\s | atom_to_list(Units)].
