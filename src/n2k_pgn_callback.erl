-module(n2k_pgn_callback).

%% If a PGN has an <ErlangModule> element in its <PGNInfo> element,
%% then decode/1 is called during decoding of the PGN message.
%%
%% This is  useful if the  format of  some fields cannot  be expressed
%% directly in the XML file, but needs a custom decode function.
%%
%% The input to the function is the message with the fields decoded by
%% the XML defintion, and the output is a message with possibly
%% additional fields.
-callback decode(n2k:data()) -> n2k:data().

%% If the decode/1 function returned fields that were not present in the XML
%% defintion, the format_val/4 function is required.  It should format the
%% given field's value as a human readable string.
-callback format_val(
    PGNName :: atom(),
    FieldName :: atom(),
    Val :: term(),
    Fields :: [{FieldName :: atom(), Val :: term()}]
) ->
    io_lib:chars().
-optional_callbacks([format_val/4]).
