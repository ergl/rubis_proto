-module(ppb_fastpsi_driver).

%% Server-side API
-export([from_client_dec/1,
         to_client_enc/2,
         from_server_dec/1]).

%% Client-side API
-export([connect/0,
         read_rc/2,
         read_request/4,
         prepare_node/3,
         decide_node_abort/2,
         decide_node_commit/3]).

-define(proto_msgs, fastpsi_msgs).
-type msg() :: binary().
-export_type([msg/0]).

%%====================================================================
%% API functions
%%====================================================================

-spec connect() -> msg().
connect() ->
    Msg = ?proto_msgs:encode_msg(#{}, 'ConnectRequest'),
    encode_raw_bits('ConnectRequest', Msg).

-spec read_rc(term(), term()) -> msg().
read_rc(Partition, Key) ->
    Msg = ?proto_msgs:encode_msg(#{partition => term_to_binary(Partition), key => term_to_binary(Key)}, 'RCReadRequest'),
    encode_raw_bits('RCReadRequest', Msg).

-spec read_request(term(), term(), term(), term()) -> msg().
read_request(Partition, Key, VCaggr, HasRead) ->
    Msg = ?proto_msgs:encode_msg(#{partition => term_to_binary(Partition),
                                   key => term_to_binary(Key),
                                   vc_aggr => term_to_binary(VCaggr),
                                   has_read => term_to_binary(HasRead)}, 'ReadRequest'),
    encode_raw_bits('ReadRequest', Msg).

-spec prepare_node(term(), term(), [{term(), term(), term()}, ...]) -> msg().
prepare_node(TxId, Protocol, Prepares) ->
    PrepareMaps = [#{partition => term_to_binary(Partition),
                     keydata => term_to_binary(KeyData),
                     version => Version} || {Partition, KeyData, Version} <- Prepares],

    Msg = ?proto_msgs:encode_msg(#{transaction_id => term_to_binary(TxId),
                                   protocol => common:encode_protocol(Protocol),
                                   prepares => PrepareMaps}, 'PrepareNode'),

    encode_raw_bits('PrepareNode', Msg).

-spec decide_node_abort([term(), ...], term()) -> msg().
decide_node_abort(Partitions, TxId) ->
    PBinary = [term_to_binary(P) || P <- Partitions],
    Msg = ?proto_msgs:encode_msg(#{partitions => PBinary,
                                   transaction_id => term_to_binary(TxId)}, 'DecideNode'),
    encode_raw_bits('DecideNode', Msg).

-spec decide_node_commit([term(), ...], term(), term()) -> msg().
decide_node_commit(Partitions, TxId, VC) ->
    PBinary = [term_to_binary(P) || P <- Partitions],
    Msg = ?proto_msgs:encode_msg(#{partitions => PBinary,
                                   transaction_id => term_to_binary(TxId),
                                   maybe_payload => {commit_vc, term_to_binary(VC)}}, 'DecideNode'),
    encode_raw_bits('DecideNode', Msg).


%% @doc Generic client-side decoding
%%
%%      Uses built-in message number to decode payload
%%
-spec from_client_dec(binary()) -> {atom(), #{}}.
from_client_dec(Bin) ->
    {Type, BinMsg} = decode_raw_bits(Bin),
    {Type, decode_from_client(Type, BinMsg)}.

decode_from_client('RCReadRequest', Msg) ->
    Map = ?proto_msgs:decode_msg(Msg, 'RCReadRequest'),
    maps:map(fun(_, Value) -> binary_to_term(Value) end, Map);

decode_from_client('ReadRequest', Msg) ->
    Map = ?proto_msgs:decode_msg(Msg, 'ReadRequest'),
    maps:map(fun(_, Value) -> binary_to_term(Value) end, Map);

decode_from_client('PrepareNode', Msg) ->
    Map = ?proto_msgs:decode_msg(Msg, 'PrepareNode'),

    DecodeInner = fun(version, V) -> V;
                     (_Key, V) -> binary_to_term(V) end,

    DecodeOuter = fun(prepares, V) -> [maps:map(DecodeInner, M) || M <- V];
                     (protocol, V) -> common:decode_protocol(V);
                     (_Key, V) -> binary_to_term(V) end,

    maps:map(DecodeOuter, Map);

decode_from_client('DecideNode', Msg) ->
    Map = ?proto_msgs:decode_msg(Msg, 'DecideNode'),
    maps:map(fun
        (partitions, Ps) -> lists:map(fun erlang:binary_to_term/1, Ps);
        (maybe_payload, {commit_vc, Bytes}) -> {ok, binary_to_term(Bytes)};
        (_, Value) -> binary_to_term(Value)
    end, Map);

decode_from_client(Type, BinMsg) ->
    ?proto_msgs:decode_msg(BinMsg, Type).

%% @doc Generic server-side encoding
%%
%%      First argument was the client command,
%%      so we can automatically determine the type of
%%      the reply.
%%
to_client_enc('ConnectRequest', {ok, {NumPartitions, Ring}}) ->
    encode_pb_msg('ConnectResponse',
                  #{num_partitions => NumPartitions, ring_payload => term_to_binary(Ring)});

to_client_enc('RCReadRequest', Value) ->
    encode_pb_msg('RCReadReturn', #{value => term_to_binary(Value)});

to_client_enc('ReadRequest', {ok, Value, VCdep, MaxVC}) ->
    encode_pb_msg('ReadReturn',
                  #{resp => {payload, #{value => term_to_binary(Value),
                                        version_vc => term_to_binary(VCdep),
                                        max_vc => term_to_binary(MaxVC)}}});

to_client_enc('ReadRequest', {error, Reason}) ->
    encode_pb_msg('ReadReturn', #{resp => {abort, common:encode_error({fastpsi, Reason})}});

to_client_enc('PrepareNode', Results) ->
    encode_pb_msg('VoteBatch', #{votes => [encode_prepare(R) || R <- Results]}).

encode_prepare({error, From, Reason}) ->
    #{partition => term_to_binary(From), payload => {abort, common:encode_error({fastpsi, Reason})}};

encode_prepare({ok, From, SeqNumber}) ->
    #{partition => term_to_binary(From), payload => {seq_number, SeqNumber}}.

%% @doc Generic client side decode
from_server_dec(Bin) ->
    {Type, Msg} = decode_raw_bits(Bin),
    decode_from_server(Type, Msg).

decode_from_server('ConnectResponse', BinMsg) ->
    #{num_partitions := N, ring_payload := Bytes} = ?proto_msgs:decode_msg(BinMsg, 'ConnectResponse'),
    {ok, N, binary_to_term(Bytes)};

decode_from_server('RCReadReturn', BinMsg) ->
    #{value := BinVal} = ?proto_msgs:decode_msg(BinMsg, 'RCReadReturn'),
    {ok, binary_to_term(BinVal)};

decode_from_server('ReadReturn', BinMsg) ->
    Resp = maps:get(resp, ?proto_msgs:decode_msg(BinMsg, 'ReadReturn')),
    case Resp of
        {abort, Code} ->
            {error, common:decode_error({fastpsi, Code})};
        {payload, #{value := V, version_vc := VC, max_vc := MaxVC}} ->
            {ok, binary_to_term(V), binary_to_term(VC), binary_to_term(MaxVC)}
    end;

decode_from_server('VoteBatch', BinMsg) ->
    #{votes := BinVotes} = ?proto_msgs:decode_msg(BinMsg, 'VoteBatch'),
    [case Resp of
        {abort, Code} ->
            {error, binary_to_term(PartitionBytes), common:decode_error({fastpsi, Code})};
        {seq_number, Num} ->
            {ok, binary_to_term(PartitionBytes), Num}
    end || #{partition := PartitionBytes, payload := Resp} <- BinVotes].


%%====================================================================
%% Internal functions
%%====================================================================

%% @doc Encode Protobug msg along with msg info
-spec encode_pb_msg(atom(), any()) -> msg().
encode_pb_msg(Type, Payload) ->
    encode_raw_bits(Type, ?proto_msgs:encode_msg(Payload, Type)).

%% @doc Encode Protobuf msg along with msg info
-spec encode_raw_bits(atom(), binary()) -> binary().
encode_raw_bits(Type, Msg) ->
    HandlerNum = common:encode_driver_module(?MODULE),
    TypeNum = encode_msg_type(Type),
    <<HandlerNum:8, TypeNum:8, Msg/binary>>.

%% @doc Return msg type and msg from raw bits
-spec decode_raw_bits(binary()) -> {atom(), binary()}.
decode_raw_bits(Bin) ->
    <<_:8, N:8, Msg/binary>> = Bin,
    {decode_type_num(N), Msg}.

%% @doc Encode msg type as ints

-spec encode_msg_type(atom()) -> non_neg_integer().
encode_msg_type('ConnectRequest') -> 1;
encode_msg_type('ConnectResponse') -> 2;
encode_msg_type('ReadRequest') -> 3;
encode_msg_type('ReadReturn') -> 4;
encode_msg_type('PrepareNode') -> 5;
encode_msg_type('VoteBatch') -> 6;
encode_msg_type('DecideNode') -> 7;
encode_msg_type('RCReadRequest') -> 8;
encode_msg_type('RCReadReturn') -> 9.


%% @doc Get original message type
-spec decode_type_num(non_neg_integer()) -> atom().
decode_type_num(1) -> 'ConnectRequest';
decode_type_num(2) -> 'ConnectResponse';
decode_type_num(3) -> 'ReadRequest';
decode_type_num(4) -> 'ReadReturn';
decode_type_num(5) -> 'PrepareNode';
decode_type_num(6) -> 'VoteBatch';
decode_type_num(7) -> 'DecideNode';
decode_type_num(8) -> 'RCReadRequest';
decode_type_num(9) -> 'RCReadReturn'.
