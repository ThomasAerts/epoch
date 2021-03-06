-module(aehttp_contracts_SUITE).

%%
%% Each test assumes that the chain is at least at the height where the latest
%% consensus protocol applies hence each test reinitializing the chain should
%% take care of that at the end of the test.
%%

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% common_test exports
-export([
         all/0, groups/0, suite/0,
         init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2
        ]).

%% Endpoint calls
-export([]).

%% test case exports
%% external endpoints
-export([
         spending_1/1,
         spending_2/1,
         spending_3/1,
         abort_test_contract/1,
         counter_contract/1,
         dutch_auction_contract/1,
         environment_contract/1,
         erc20_token_contract/1,
         factorial_contract/1,
         fundme_contract/1,
         identity_contract/1,
         maps_contract/1,
         polymorphism_test_contract/1,
         simple_storage_contract/1,
         spend_test_contract/1,
         stack_contract/1,
         null/1
        ]).

-define(NODE, dev1).
-define(DEFAULT_TESTS_COUNT, 5).
-define(WS, aehttp_ws_test_utils).

all() ->
    [
     {group, contracts}
    ].

groups() ->
    [
     {contracts, [],
      [
       spending_1,
       spending_2,
       spending_3,
       identity_contract,
       abort_test_contract,
       simple_storage_contract,
       counter_contract,
       stack_contract,
       polymorphism_test_contract,
       factorial_contract,
       maps_contract,
       environment_contract,
       spend_test_contract,
       dutch_auction_contract,
       fundme_contract,
       erc20_token_contract,
       null                                     %This allows to end with ,
      ]}
    ].

suite() ->
    [].

init_per_suite(Config) ->
    ok = application:ensure_started(erlexec),
    DataDir = ?config(data_dir, Config),
    TopDir = aecore_suite_utils:top_dir(DataDir),
    Config1 = [{symlink_name, "latest.http_contracts"},
               {top_dir, TopDir},
               {test_module, ?MODULE}] ++ Config,
    aecore_suite_utils:make_shortcut(Config1),
    ct:log("Environment = ~p", [[{args, init:get_arguments()},
                                 {node, node()},
                                 {cookie, erlang:get_cookie()}]]),
    Forks = aecore_suite_utils:forks(),

    aecore_suite_utils:create_configs(Config1, #{<<"chain">> =>
                                                 #{<<"persist">> => true,
                                                   <<"hard_forks">> => Forks}}),
    aecore_suite_utils:make_multi(Config1, [?NODE]),
    [{nodes, [aecore_suite_utils:node_tuple(?NODE)]}]  ++ Config1.

end_per_suite(_Config) ->
    ok.

init_per_group(contracts, Config) ->
    NodeName = aecore_suite_utils:node_name(?NODE),
    aecore_suite_utils:start_node(?NODE, Config),
    aecore_suite_utils:connect(NodeName),

    aecore_suite_utils:mine_key_blocks(NodeName, 3),

    %% Prepare accounts, Alice, Bert, Carl and Diana.

    StartAmt = 100000,
    {APubkey, APrivkey, _} = new_account(StartAmt),
    {BPubkey, BPrivkey, _} = new_account(StartAmt),
    {CPubkey, CPrivkey, _} = new_account(StartAmt),
    {DPubkey, DPrivkey, _} = new_account(StartAmt),

    {ok, [_KeyBlock,Block]} = aecore_suite_utils:mine_blocks(NodeName, 2),
    Txs = [_Spend1,_Spend2,_Spend3,_Spend4] = aec_blocks:txs(Block),
    ct:pal("Block txs ~p\n", [Txs]),

    %% Save account information.
    Accounts = #{acc_a => #{pub_key => APubkey,
                            priv_key => APrivkey,
                            start_amt => StartAmt},
                 acc_b => #{pub_key => BPubkey,
                            priv_key => BPrivkey,
                            start_amt => StartAmt},
                 acc_c => #{pub_key => CPubkey,
                            priv_key => CPrivkey,
                            start_amt => StartAmt},
                 acc_d => #{pub_key => DPubkey,
                            priv_key => DPrivkey,
                            start_amt => StartAmt}},
    [{accounts,Accounts},{node_name,NodeName}|Config];
init_per_group(_Group, Config) ->
    NodeName = aecore_suite_utils:node_name(?NODE),
    aecore_suite_utils:start_node(?NODE, Config),
    aecore_suite_utils:connect(NodeName),
    ToMine = max(2, aecore_suite_utils:latest_fork_height()),
    ct:pal("ToMine ~p\n", [ToMine]),
    aecore_suite_utils:mine_key_blocks(NodeName, ToMine),
    [{node_name,NodeName}|Config].

end_per_group(_Group, Config) ->
    RpcFun = fun(M, F, A) -> rpc(?NODE, M, F, A) end,
    {ok, DbCfg} = aecore_suite_utils:get_node_db_config(RpcFun),
    aecore_suite_utils:stop_node(?NODE, Config),
    aecore_suite_utils:delete_node_db_if_persisted(DbCfg),
    ok.

init_per_testcase(_Case, Config) ->
    [{tc_start, os:timestamp()}|Config].

end_per_testcase(_Case, Config) ->
    Ts0 = ?config(tc_start, Config),
    ct:log("Events during TC: ~p", [[{N, aecore_suite_utils:all_events_since(N, Ts0)}
                                     || {_,N} <- ?config(nodes, Config)]]),
    ok.

%% ============================================================
%% Test cases
%% ============================================================

%% null(Config)
%%  Does nothing and always succeeds.

null(_Config) ->
    ok.

%% spending_1(Config)
%%  A simple test of tokens from acc_a to acc_b.

spending_1(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey}} = proplists:get_value(accounts, Config),

    %% Check initial balances.
    ABal0 = get_balance(APubkey),
    BBal0 = get_balance(BPubkey),
    ct:pal("Balances 0: ~p, ~p\n", [ABal0,BBal0]),

    %% Add tokens to both accounts and wait until done.
    {ok,200,#{<<"tx">> := ATx}} =
        post_spend_tx(aec_base58c:encode(account_pubkey, APubkey), 500, 1),
    SignedATx = sign_tx(ATx),
    {ok, 200, #{<<"tx_hash">> := ATxHash}} = post_tx(SignedATx),
    ok = wait_for_tx_hash_on_chain(NodeName, ATxHash),

    {ok,200,#{<<"tx">> := BTx}} =
        post_spend_tx(aec_base58c:encode(account_pubkey, BPubkey), 500, 1),
    SignedBTx = sign_tx(BTx),
    {ok, 200, #{<<"tx_hash">> := BTxHash}} = post_tx(SignedBTx),

    ok = wait_for_tx_hash_on_chain(NodeName, BTxHash),

    %% Get balances after mining.
    ABal1 = get_balance(APubkey),
    BBal1 = get_balance(BPubkey),
    ct:pal("Balances 1: ~p, ~p\n", [ABal1,BBal1]),

    %% Amount transfered and fee.
    Amount = 200,
    Fee = 5,

    %% Transfer money from Alice to Bert.
    TxHash = spend_tokens(APubkey, APrivkey, BPubkey, Amount, Fee),
    ok = wait_for_tx_hash_on_chain(NodeName, TxHash),

    %% Check that tx has succeeded.
    ?assert(tx_in_chain(TxHash)),

    %% Check balances after sending.
    ABal2 = get_balance(APubkey),
    BBal2 = get_balance(BPubkey),
    ct:pal("Balances 2: ~p, ~p\n", [ABal2,BBal2]),

    %% Check that the balances are correct, don't forget the fee.
    ABal2 = ABal1 - Amount - Fee,
    BBal2 = BBal1 + Amount,

    ok.

%% spending_2(Config)
%%  A simple test of tokens from acc_a to acc_b. There are not enough
%%  tokens in acc_a so tx suspends until TTL runs out.

spending_2(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey}} = proplists:get_value(accounts, Config),

    %% Check initial balances.
    ABal0 = get_balance(APubkey),
    BBal0 = get_balance(BPubkey),
    ct:pal("Balances 0: ~p, ~p\n", [ABal0,BBal0]),

    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Get balances after mining.
    ABal1 = get_balance(APubkey),
    BBal1 = get_balance(BPubkey),
    ct:pal("Balances 1: ~p, ~p\n", [ABal1,BBal1]),

    {ok,200,#{<<"key_block">> := #{<<"height">> := Height}}} = get_top(),
    ct:pal("Height ~p\n", [Height]),

    %% Transfer money from Alice to Bert, but more than Alice has.
    TTL =  #{ttl => Height + 2},
    TxHash = spend_tokens(APubkey, APrivkey, BPubkey, ABal1 + 100, 5, TTL),
    {ok,[_, _]} = aecore_suite_utils:mine_key_blocks(NodeName, 2),

    %% Check that tx has failed.
    ?assertNot(tx_in_chain(TxHash)),

    %% Check that there has been no transfer.
    ABal2 = get_balance(APubkey),
    BBal2 = get_balance(BPubkey),
    ABal2 = ABal1,
    BBal2 = BBal1,
    ct:pal("Balances 2: ~p, ~p\n", [ABal2,BBal2]),

    %% Wait until TTL has been passed.
    {ok,[_,_]} = aecore_suite_utils:mine_blocks(NodeName, 2),

    %% Check that tx has failed.
    ?assertNot(tx_in_chain(TxHash)),

    ok.

%% spending_3(Config)
%%  A simple test of tokens from acc_a to acc_b. There are not enough
%%  tokens in acc_a so tx suspends until acc_a gets enough.

spending_3(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey}} = proplists:get_value(accounts, Config),

    %% Check initial balances.
    ABal0 = get_balance(APubkey),
    BBal0 = get_balance(BPubkey),
    ct:pal("Balances 0: ~p, ~p\n", [ABal0,BBal0]),

    {ok,[_,_]} = aecore_suite_utils:mine_key_blocks(NodeName, 2),

    %% Get balances after mining.
    ABal1 = get_balance(APubkey),
    BBal1 = get_balance(BPubkey),
    ct:pal("Balances 1: ~p, ~p\n", [ABal1,BBal1]),

    %% Transfer money from Alice to Bert, but more than Alice has.
    SpendTxHash = spend_tokens(APubkey, APrivkey, BPubkey, ABal1 + 200, 5),
    {ok,[_,_]} = aecore_suite_utils:mine_key_blocks(NodeName, 2),

    %% Check that tx has failed.
    ?assertNot(tx_in_chain(SpendTxHash)),

    %% Check that there has been no transfer.
    ABal2 = get_balance(APubkey),
    BBal2 = get_balance(BPubkey),
    ABal2 = ABal1,
    BBal2 = BBal1,
    ct:pal("Balances 2: ~p, ~p\n", [ABal2,BBal2]),

    %% Now we add enough tokens to acc_a so it can do the spend tx.
    {ok,200,#{<<"tx">> := PostTx}} =
        post_spend_tx(aec_base58c:encode(account_pubkey, APubkey), 500, 1),
    SignedPostTx = sign_tx(PostTx),
    {ok, 200, #{<<"tx_hash">> := PostTxHash}} = post_tx(SignedPostTx),

    ok = wait_for_tx_hash_on_chain(NodeName, PostTxHash),
    ok = wait_for_tx_hash_on_chain(NodeName, SpendTxHash),

    %% Check that tx has succeeded.
    ?assert(tx_in_chain(SpendTxHash)),

    %% Check the balance to see what happened.
    ABal3 = get_balance(APubkey),
    BBal3 = get_balance(BPubkey),
    ct:pal("Balances 3: ~p, ~p\n", [ABal3,BBal3]),

    ok.

%% identity_contract(Config)
%%  Create the Identity contract by account acc_c and call by accounts
%%  acc_c and acc_d. Encode create and call data in server.

identity_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_c := #{pub_key := CPubkey,
                 priv_key := CPrivkey},
      acc_d := #{pub_key := DPubkey,
                 priv_key := DPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    ensure_balance(CPubkey, 50000),
    ensure_balance(DPubkey, 50000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "identity.aes"
    Code = compile_test_contract("identity"),

    %% Initialise contract, owned by Carl.
    {EncodedContractPubkey,_,_} =
        create_compute_contract(NodeName, CPubkey, CPrivkey, Code, <<"()">>),

    %% Call contract main function by Carl.
    {CReturn,_} = call_compute_func(NodeName, CPubkey, CPrivkey,
                                    EncodedContractPubkey,
                                    <<"main">>, <<"(42)">>),
    #{<<"value">> := 42} = decode_data(<<"int">>, CReturn),

    %% Call contract main function by Diana.
    {DReturn,_} = call_compute_func(NodeName, DPubkey, DPrivkey,
                                    EncodedContractPubkey,
                                    <<"main">>, <<"(42)">>),
    #{<<"value">> := 42} = decode_data(<<"int">>, DReturn),

    ok.

%% abort_test_contract(Config)
%%  Test the built-in abort function.

abort_test_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "abort_test.aes"
    Code = compile_test_contract("abort_test"),

    {EncodedContractPubkey,_,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code, <<"()">>),

    error_call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                            <<"do_abort_1">>, <<"(\"yogi bear\")">>),
    error_call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                            <<"do_abort_2">>, <<"(\"yogi bear\")">>),

    ok.

%% simple_storage_contract(Config)
%%  Create the SimpleStorage contract by acc_a and test and set its
%%  state data by acc_a, acc_b, acc_c and finally by acc_d.

simple_storage_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey},
      acc_c := #{pub_key := CPubkey,
                 priv_key := CPrivkey},
      acc_d := #{pub_key := DPubkey,
                 priv_key := DPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 100000),
    _BBal0 = ensure_balance(BPubkey, 100000),
    _CBal0 = ensure_balance(CPubkey, 100000),
    _DBal0 = ensure_balance(DPubkey, 100000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "simple_storage.aes"
    Code = compile_test_contract("simple_storage"),

    %% Initialise contract, owned by Alice.
    {EncodedContractPubkey,_,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code, <<"(21)">>),

    %% Call contract get function by Alice.
    AGetValue1 = call_get(NodeName, APubkey, APrivkey, EncodedContractPubkey),
    #{<<"value">> := 21} = decode_data(<<"int">>, AGetValue1),

    %% Call contract set function by Alice.
    call_set(NodeName, APubkey, APrivkey, EncodedContractPubkey, <<"(42)">>),

    %% Call contract get function by Bert.
    BGetValue1 = call_get(NodeName, BPubkey, BPrivkey, EncodedContractPubkey),
    #{<<"value">> := 42} = decode_data(<<"int">>, BGetValue1),

    %% Call contract set function by Bert.
    call_set(NodeName, BPubkey, BPrivkey, EncodedContractPubkey, <<"(84)">>),

    %% Call contract get function by Carl.
    CGetValue1 = call_get(NodeName, CPubkey, CPrivkey, EncodedContractPubkey),
    #{<<"value">> := 84} = decode_data(<<"int">>, CGetValue1),

    %% Call contract set function by Carl.
    call_set(NodeName, CPubkey, CPrivkey, EncodedContractPubkey, <<"(126)">>),

    %% Call contract get function by Diana.
    DGetValue1 = call_get(NodeName, DPubkey, DPrivkey, EncodedContractPubkey),
    #{<<"value">> := 126} = decode_data(<<"int">>, DGetValue1),

    %% Call contract set function by Diana.
    call_set(NodeName, DPubkey, DPrivkey, EncodedContractPubkey, <<"(168)">>),

    %% Call contract get function by Alice.
    AGetValue2 = call_get(NodeName, APubkey, APrivkey, EncodedContractPubkey),
    #{<<"value">> := 168 } = decode_data(<<"int">>, AGetValue2),

    %% ct:pal("A Balances ~p, ~p\n", [ABal0,get_balance(APubkey)]),
    %% ct:pal("B Balances ~p, ~p\n", [BBal0,get_balance(BPubkey)]),
    %% ct:pal("C Balances ~p, ~p\n", [CBal0,get_balance(CPubkey)]),
    %% ct:pal("D Balances ~p, ~p\n", [DBal0,get_balance(DPubkey)]),

    ok.

call_get(NodeName, Pubkey, Privkey, EncodedContractPubkey) ->
    {Value,_Return} =
        call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                          <<"get">>, <<"()">>),
    Value.

call_set(NodeName, Pubkey, Privkey, EncodedContractPubkey, SetArg) ->
    {Value,_Return} =
        call_compute_func(NodeName, Pubkey, Privkey,
                          EncodedContractPubkey, <<"set">>, SetArg),
    Value.

%% counter_contract(Config)
%%  Create the Counter contract by acc_b, tick it by acc_a and then
%%  check value by acc_a.

counter_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 50000),
    _BBal0 = ensure_balance(BPubkey, 50000),

    %% Compile test contract "counter.aes"
    Code = compile_test_contract("counter"),

    %% Initialise contract, owned by Bert.
    {EncodedContractPubkey,_,_} =
        create_compute_contract(NodeName, BPubkey, BPrivkey, Code, <<"(21)">>),

    %% Call contract get function by Bert.
    {BGetValue1,_} =
        call_compute_func(NodeName, BPubkey, BPrivkey, EncodedContractPubkey,
                          <<"get">>, <<"()">>),
    #{<<"value">> := 21} = decode_data(<<"int">>, BGetValue1),

    %% Call contract tick function 5 times by Alice.
    call_tick(NodeName, APubkey, APrivkey, EncodedContractPubkey),
    call_tick(NodeName, APubkey, APrivkey, EncodedContractPubkey),
    call_tick(NodeName, APubkey, APrivkey, EncodedContractPubkey),
    call_tick(NodeName, APubkey, APrivkey, EncodedContractPubkey),
    call_tick(NodeName, APubkey, APrivkey, EncodedContractPubkey),

    %% Call contract get function by Bert and check we have 26 ticks.
    {BGetValue2,_} =
        call_compute_func(NodeName, BPubkey, BPrivkey, EncodedContractPubkey,
                          <<"get">>, <<"()">>),
    #{<<"value">> := 26 } = decode_data(<<"int">>, BGetValue2),

    ok.

call_tick(NodeName, Pubkey, Privkey, EncodedContractPubkey) ->
    call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                      <<"tick">>, <<"()">>).

%% stack(Config)
%%  Create the Stack contract by acc_a and push and pop elements by
%%  acc_a, acc_b, acc_c and acc_d

stack_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey},
      acc_c := #{pub_key := CPubkey,
                 priv_key := CPrivkey},
      acc_d := #{pub_key := DPubkey,
                 priv_key := DPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    _BBal0 = ensure_balance(BPubkey, 500000),
    _CBal0 = ensure_balance(CPubkey, 500000),
    _DBal0 = ensure_balance(DPubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "stack.aes"
    Code = compile_test_contract("stack"),

    %% Create the contract with 2 elements in the stack.
    {EncodedContractPubkey,_,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code,
                                <<"([\"two\",\"one\"])">>),

    %% Test the size.
    2 = call_size(NodeName, APubkey, APrivkey, EncodedContractPubkey),

    %% Push 2 more elements.
    call_compute_func(NodeName, BPubkey, BPrivkey, EncodedContractPubkey,
                      <<"push">>, <<"(\"three\")">>),
    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedContractPubkey,
                      <<"push">>, <<"(\"four\")">>),
    %% Test the size.
    4 = call_size(NodeName, DPubkey, DPrivkey, EncodedContractPubkey),

    %% Check the stack.
    Stack = call_func_decode(NodeName, DPubkey, DPrivkey,
                             EncodedContractPubkey, <<"all">>, <<"()">>,
                             <<"list(string)">>),
    [#{<<"type">> := <<"string">>,<<"value">> := <<"four">>},
     #{<<"type">> := <<"string">>,<<"value">> := <<"three">>},
     #{<<"type">> := <<"string">>,<<"value">> := <<"two">>},
     #{<<"type">> := <<"string">>,<<"value">> := <<"one">>}] = Stack,

    %% Pop the values and check we get them in the right order.
    <<"four">> = call_pop(NodeName, APubkey, APrivkey, EncodedContractPubkey),
    <<"three">> = call_pop(NodeName, BPubkey, BPrivkey, EncodedContractPubkey),
    <<"two">> = call_pop(NodeName, CPubkey, CPrivkey, EncodedContractPubkey),
    <<"one">> = call_pop(NodeName, DPubkey, DPrivkey, EncodedContractPubkey),

    %% The resulting stack is empty.
    0 = call_size(NodeName, APubkey, APrivkey, EncodedContractPubkey),

    ok.

call_size(NodeName, Pubkey, Privkey, EncodedContractPubkey) ->
    call_func_decode(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                     <<"size">>, <<"()">>, <<"int">>).

call_pop(NodeName, Pubkey, Privkey, EncodedContractPubkey) ->
    call_func_decode(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                     <<"pop">>, <<"()">>, <<"string">>).

%% polymorphism_test_contract(Config)
%%  Check the polymorphism_test contract.
%%  This does not work yet.

polymorphism_test_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "polymorphism_test.aes".
    Code = compile_test_contract("polymorphism_test"),

    %% Initialise contract owned by Alice.
    {EncodedContractPubkey,_,_} =
       create_compute_contract(NodeName, APubkey, APrivkey, Code, <<"()">>),

    %% Test the polymorphism.
    %% TODO: currently we just test that it works but we should check
    %% the return values as well.
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"foo">>, <<"()">>),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"bar">>, <<"()">>),

    ok.

%% factorial_contract(Config)
%%  Check the factorial contract.

factorial_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "factorial.aes".
    Code = compile_test_contract("factorial"),

    %% Initialise contract owned by Alice.
    {EncodedContractPubkey,DecodedContractPubkey,_} =
       create_compute_contract(NodeName, APubkey, APrivkey, Code, <<"(0)">>),

    %% Set worker contract. A simple way of pointing the contract to itself.
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"set_worker">>,
                      args_to_binary([DecodedContractPubkey])),

    %% Compute fac(10) = 3628800.
    {Ret,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                EncodedContractPubkey, <<"fac">>, <<"(10)">>),
    #{<<"value">> := 3628800} = decode_data(<<"int">>, Ret),

    ok.

%% maps_contract(Config)
%%  Check the Maps contract. We need an interface contract here as
%%  there is no way pass record as an argument over the http API.

maps_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey},
      acc_c := #{pub_key := CPubkey,
                 priv_key := CPrivkey},
      acc_d := #{pub_key := DPubkey,
                 priv_key := DPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    _BBal0 = ensure_balance(BPubkey, 500000),
    _CBal0 = ensure_balance(CPubkey, 500000),
    _DBal0 = ensure_balance(DPubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "maps.aes".
    MCode = compile_test_contract("maps"),

    %% Initialise contract owned by Alice.
    {EncodedMapsPubkey,DecodedMapsPubkey,_} =
       create_compute_contract(NodeName, APubkey, APrivkey, MCode, <<"()">>),

    %% Compile the interface contract "test_maps.aes".
    TestMapsFile = proplists:get_value(data_dir, Config) ++ "test_maps.aes",
    {ok,SophiaCode} = file:read_file(TestMapsFile),
    {ok, 200, #{<<"bytecode">> := TCode}} = get_contract_bytecode(SophiaCode),

    {EncodedTestPubkey,_,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, TCode,
                                args_to_binary([DecodedMapsPubkey])),

    %% Set state {[k] = v}
    %% State now {map_i = {[1]=>{x=1,y=2},[2]=>{x=3,y=4},[3]=>{x=5,y=6}},
    %%            map_s = ["one"]=> ... , ["two"]=> ... , ["three"] => ...}
    call_compute_func(NodeName, BPubkey, BPrivkey, EncodedMapsPubkey,
                      <<"map_state_i">>, <<"()">>),
    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedMapsPubkey,
                      <<"map_state_s">>, <<"()">>),

    %% Print current state
    ct:pal("State ~p\n", [call_get_state(NodeName, APubkey, APrivkey,
                                         EncodedMapsPubkey)]),

    %% m[k]

    [#{<<"type">> := <<"word">>, <<"value">> := 3},
     #{<<"type">> := <<"word">>, <<"value">> := 4}] =
        call_get_state_i(NodeName, BPubkey, BPrivkey, EncodedMapsPubkey,
                         <<"(2)">>),
    [#{<<"type">> := <<"word">>, <<"value">> := 5},
     #{<<"type">> := <<"word">>, <<"value">> := 6}] =
        call_get_state_s(NodeName, BPubkey, BPrivkey, EncodedMapsPubkey,
                         <<"(\"three\")">>),

    %% m{[k] = v}
    %% State now {map_i = {[1]=>{x=11,y=22},[2]=>{x=3,y=4},[3]=>{x=5,y=6}},
    %%            map_s = ["one"]=> ... , ["two"]=> ... , ["three"] => ...}
    %% Need to call interface functions as cannot create record as argument.

    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedTestPubkey,
                      <<"set_state_i">>, <<"(1, 11, 22)">>),
    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedTestPubkey,
                      <<"set_state_s">>, <<"(\"one\", 11, 22)">>),

    [#{<<"value">> := 11}, #{<<"value">> := 22}] =
        call_get_state_i(NodeName, CPubkey, CPrivkey, EncodedMapsPubkey,
                         <<"(1)">>),
    [#{<<"value">> := 11}, #{<<"value">> := 22}] =
        call_get_state_s(NodeName, CPubkey, CPrivkey, EncodedMapsPubkey,
                         <<"(\"one\")">>),

    %% m{f[k].x = v}

    call_compute_func(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                      <<"setx_state_i">>, <<"(2, 33)">>),
    call_compute_func(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                      <<"setx_state_s">>, <<"(\"two\", 33)">>),

    [#{<<"value">> := 33}, #{<<"value">> := 4}] =
        call_get_state_i(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                         <<"(2)">>),
    [#{<<"value">> := 33}, #{<<"value">> := 4}] =
        call_get_state_s(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                         <<"(\"two\")">>),

    %% Map.member
    %% Check keys 1 and "one" which exist and 10 and "ten" which don't.

    1 = call_member_state_i(NodeName, BPubkey, BPrivkey, EncodedMapsPubkey,
                            <<"(1)">>),
    0 = call_member_state_i(NodeName, BPubkey, BPrivkey, EncodedMapsPubkey,
                            <<"(10)">>),

    1 = call_member_state_s(NodeName, BPubkey, BPrivkey, EncodedMapsPubkey,
                            <<"(\"one\")">>),
    0 = call_member_state_s(NodeName, BPubkey, BPrivkey, EncodedMapsPubkey,
                            <<"(\"ten\")">>),

    %% Map.lookup
    %% The values of map keys 3 and "three" are unchanged, keys 10 and
    %% "ten" don't exist.

    {IL1Value,_} = call_compute_func(NodeName, CPubkey, CPrivkey,
                                     EncodedMapsPubkey,
                                     <<"lookup_state_i">>, <<"(3)">>),
    #{<<"type">> := <<"variant">>,
      <<"value">> := [1, #{<<"value">> := [#{<<"value">> := 5},
                                           #{<<"value">> := 6}]}]} =
        decode_data(<<"option((int, int))">>, IL1Value),
    {IL2Value,_} = call_compute_func(NodeName, CPubkey, CPrivkey,
                                     EncodedMapsPubkey,
                                     <<"lookup_state_i">>, <<"(10)">>),
    #{<<"type">> := <<"variant">>,
      <<"value">> := [0]} =
        decode_data(<<"option((int, int))">>, IL2Value),

    {SL1Value,_} = call_compute_func(NodeName, CPubkey, CPrivkey,
                                     EncodedMapsPubkey,
                                     <<"lookup_state_s">>, <<"(\"three\")">>),
    #{<<"type">> := <<"variant">>,
      <<"value">> := [1, #{<<"value">> := [#{<<"value">> := 5},
                                           #{<<"value">> := 6}]}]} =
        decode_data(<<"option((int, int))">>, SL1Value),
    {SL2Value,_} = call_compute_func(NodeName, CPubkey, CPrivkey,
                                     EncodedMapsPubkey,
                                     <<"lookup_state_s">>, <<"(\"ten\")">>),
    #{<<"type">> := <<"variant">>,
      <<"value">> := [0]} =
        decode_data(<<"option((int, int))">>, SL2Value),

    %% Map.delete
    %% Check map keys 3 and "three" exist, delete them and check that
    %% they have gone, then put them back for future use.

    1 = call_member_state_i(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                            <<"(3)">>),
    1 = call_member_state_s(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                            <<"(\"three\")">>),

    call_compute_func(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                      <<"delete_state_i">>, <<"(3)">>),
    call_compute_func(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                      <<"delete_state_s">>, <<"(\"three\")">>),

    0 = call_member_state_i(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                            <<"(3)">>),
    0 = call_member_state_s(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                            <<"(\"three\")">>),

    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedTestPubkey,
                      <<"set_state_i">>, <<"(3, 5, 6)">>),
    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedTestPubkey,
                      <<"set_state_s">>, <<"(\"three\", 5, 6)">>),

    %% Map.size
    %% Both of these still contain 3 elements.

    {ISValue,_} = call_compute_func(NodeName, BPubkey, BPrivkey,
                                    EncodedMapsPubkey,
                                    <<"size_state_i">>, <<"()">>),
    #{<<"value">> := 3} = decode_data(<<"int">>, ISValue),
    {SSValue,_} = call_compute_func(NodeName, BPubkey, BPrivkey,
                                    EncodedMapsPubkey,
                                    <<"size_state_s">>, <<"()">>),
    #{<<"value">> := 3} = decode_data(<<"int">>, SSValue),

    %% Map.to_list, Map.from_list then test if element is there.

    call_compute_func(NodeName, DPubkey, DPrivkey, EncodedTestPubkey,
                      <<"list_state_i">>, <<"(242424)">>),
    1 = call_member_state_i(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                            <<"(242424)">>),
    call_compute_func(NodeName, DPubkey, DPrivkey, EncodedTestPubkey,
                      <<"list_state_s">>, <<"(\"xxx\")">>),
    1 = call_member_state_s(NodeName, DPubkey, DPrivkey, EncodedMapsPubkey,
                            <<"(\"xxx\")">>),

    ok.

call_member_state_i(NodeName, Pubkey, Privkey, EncodedMapsPubkey, MemberArg) ->
    call_func_decode(NodeName, Pubkey, Privkey, EncodedMapsPubkey,
                     <<"member_state_i">>, MemberArg, <<"bool">>).

call_member_state_s(NodeName, Pubkey, Privkey, EncodedMapsPubkey, MemberArg) ->
    call_func_decode(NodeName, Pubkey, Privkey, EncodedMapsPubkey,
                     <<"member_state_s">>, MemberArg, <<"bool">>).

call_get_state(NodeName, Pubkey, Privkey, EncodedMapsPubkey) ->
    StateType = <<"( map(int, (int, int)), map(string, (int, int)) )">>,
    {Return,_} = call_compute_func(NodeName, Pubkey, Privkey,
                                   EncodedMapsPubkey,
                                   <<"get_state">>, <<"()">>),
    #{<<"value">> := GetState} = decode_data(StateType, Return),
    GetState.

call_get_state_i(NodeName, Pubkey, Privkey, EncodedMapsPubkey, GetArg) ->
    {GSValue,_} = call_compute_func(NodeName, Pubkey, Privkey,
                                    EncodedMapsPubkey,
                                    <<"get_state_i">>, GetArg),
    #{<<"value">> := GetValue} = decode_data(<<"(int, int)">>, GSValue),
    GetValue.

call_get_state_s(NodeName, Pubkey, Privkey, EncodedMapsPubkey, GetArg) ->
    {GSValue,_} = call_compute_func(NodeName, Pubkey, Privkey,
                                    EncodedMapsPubkey,
                                    <<"get_state_s">>, GetArg),
    #{<<"value">> := GetValue} = decode_data(<<"(int, int)">>, GSValue),
    GetValue.

%% enironment_contract(Config)
%%  Check the Environment contract. We don't always check values and
%%  the nested calls don't seem to work yet.

environment_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey},
      acc_c := #{pub_key := CPubkey,
                 priv_key := CPrivkey},
      acc_d := #{pub_key := DPubkey,
                 priv_key := DPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    ABal0 = ensure_balance(APubkey, 500000),
    BBal0 = ensure_balance(BPubkey, 500000),
    CBal0 = ensure_balance(CPubkey, 500000),
    DBal0 = ensure_balance(DPubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "environment.aes"
    Code = compile_test_contract("environment"),

    ContractBalance = 10000,

    %% Initialise contract owned by Alice setting balance to 10000.
    {EncodedContractPubkey,DecodedContractPubkey,_} =
        create_compute_contract(NodeName, APubkey, APrivkey,
                                Code, <<"(0)">>, #{amount => ContractBalance}),

    %% Get the initial balance.
    ABal1 = get_balance(APubkey),

    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"set_remote">>,
                      args_to_binary([DecodedContractPubkey])),

    %% Address.
    ct:pal("Calling contract_address\n"),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"contract_address">>, <<"()">>),
    ct:pal("Calling nested_address\n"),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"nested_address">>,
                      args_to_binary([DecodedContractPubkey])),

    %% Balance.
    ct:pal("Calling contract_balance\n"),
    {CBValue,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                    EncodedContractPubkey,
                                   <<"contract_balance">>, <<"()">>),
    #{<<"value">> := ContractBalance} = decode_data(<<"int">>, CBValue),

    %% Origin.
    ct:pal("Calling call_origin\n"),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"call_origin">>, <<"()">>),

    ct:pal("Calling nested_origin\n"),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"nested_origin">>, <<"()">>),

    %% Caller.
    ct:pal("Calling call_caller\n"),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"call_caller">>, <<"()">>),
    ct:pal("Calling nested_caller\n"),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"nested_caller">>, <<"()">>),

    %% Value.
    ct:pal("Calling call_value\n"),
    ExpectedValue = 5,
    {CVValue,_} = call_compute_func(NodeName, BPubkey, BPrivkey,
                                    EncodedContractPubkey,
                                    <<"call_value">>, <<"()">>,
                                    #{amount => ExpectedValue}
                                   ),
    #{<<"value">> := CallValue} = decode_data(<<"int">>, CVValue),
    ct:pal("Call value ~p\n", [CallValue]),
    ?assertEqual(ExpectedValue, CallValue),
    ct:pal("Calling nested_value\n"),
    {NestedValue, _} = call_compute_func(NodeName, BPubkey, BPrivkey,
                                         EncodedContractPubkey,
                                         <<"nested_value">>, <<"(42)">>),
    ct:pal("Nested value ~p\n", [NestedValue]),

    %% Gas price.
    ct:pal("Calling call_gas_price\n"),
    ExpectedGasPrice = 2,
    {GPValue,_} = call_compute_func(NodeName, BPubkey, BPrivkey,
                                    EncodedContractPubkey,
                                    <<"call_gas_price">>, <<"()">>,
                                    #{gas_price => ExpectedGasPrice}
                                   ),
    #{<<"value">> := GasPrice} = decode_data(<<"int">>, GPValue),
    ct:pal("Gas price ~p\n", [GasPrice]),
    ?assertEqual(ExpectedGasPrice, GasPrice),

    %% Account balances.
    ct:pal("Calling get_balance twice\n"),
    {BBalValue,_} = call_compute_func(NodeName, BPubkey, BPrivkey,
                                      EncodedContractPubkey,
                                      <<"get_balance">>,
                                      args_to_binary([BPubkey])),
    #{<<"value">> := BBalance} = decode_data(<<"int">>, BBalValue),
    ct:pal("Balance B ~p\n", [BBalance]),

    {DBalValue,_} = call_compute_func(NodeName, BPubkey, BPrivkey,
                                      EncodedContractPubkey,
                                      <<"get_balance">>,
                                      args_to_binary([DPubkey])),
    #{<<"value">> := DBalance} = decode_data(<<"int">>, DBalValue),
    ct:pal("Balance D ~p\n", [DBalance]),

    %% Block hash.
    ct:pal("Calling block_hash\n"),
    {BHValue,_} = call_compute_func(NodeName, CPubkey, CPrivkey,
                                    EncodedContractPubkey,
                                    <<"block_hash">>, <<"(21)">>),
    #{<<"value">> := BlockHashValue} = decode_data(<<"int">>, BHValue),
    {ok, 200, #{<<"hash">> := ExpectedBlockHash}} = get_key_block_at_height(21),
    ct:pal("Block hash ~p\n", [BlockHashValue]),
    ?assertEqual({key_block_hash, <<BlockHashValue:256/integer-unsigned>>},
                 aec_base58c:decode(ExpectedBlockHash)),

    %% Block hash. With value out of bounds
    ct:pal("Calling block_hash\n"),
    {BHValue1,_} = call_compute_func(NodeName, CPubkey, CPrivkey,
                                    EncodedContractPubkey,
                                    <<"block_hash">>, <<"(10000000)">>),
    #{<<"value">> := BlockHashValue1} = decode_data(<<"int">>, BHValue1),
    ct:pal("Block hash ~p\n", [BlockHashValue1]),
    ?assertEqual(0, BlockHashValue1),

    %% Coinbase.
    ct:pal("Calling coinbase\n"),
    {CoinBaseValue, #{header := CBHeader}} =
        call_compute_func(NodeName, CPubkey, CPrivkey,
                          EncodedContractPubkey,
                          <<"coinbase">>, <<"()">>),
    #{<<"value">> := CoinBase} = decode_data(<<"address">>, CoinBaseValue),
    ct:pal("CoinBase ~p\n", [CoinBase]),
    #{<<"prev_key_hash">> := CBKeyHash} = CBHeader,
    ExpectedBeneficiary = aec_base58c:encode(account_pubkey, <<CoinBase:256>>),
    ?assertMatch({ok, 200, #{<<"beneficiary">> := ExpectedBeneficiary}},
                 get_key_block(CBKeyHash)),

    %% Block timestamp.
    ct:pal("Calling timestamp\n"),
    {TimeStampValue, #{header := TSHeader}} =
        call_compute_func(NodeName, CPubkey, CPrivkey,
                          EncodedContractPubkey,
                          <<"timestamp">>, <<"()">>),
    #{<<"value">> := TimeStamp} = decode_data(<<"int">>, TimeStampValue),
    ct:pal("Timestamp ~p\n", [TimeStamp]),
    ?assertEqual(maps:get(<<"time">>, TSHeader), TimeStamp),

    %% Block height.
    ct:pal("Calling block_height\n"),
    {HeightValue,#{header := HeightHeader}} =
        call_compute_func(NodeName, DPubkey, DPrivkey,
                          EncodedContractPubkey,
                          <<"block_height">>, <<"()">>),
    #{<<"value">> := BlockHeight} = decode_data(<<"int">>, HeightValue),
    ct:pal("Block height ~p\n", [BlockHeight]),
    ?assertEqual(maps:get(<<"height">>, HeightHeader), BlockHeight),

    %% Difficulty.
    ct:pal("Calling difficulty\n"),
    {DiffValue,#{header := DiffHeader}} =
        call_compute_func(NodeName, DPubkey, DPrivkey,
                          EncodedContractPubkey,
                          <<"difficulty">>, <<"()">>),
    #{<<"value">> := Difficulty} = decode_data(<<"int">>, DiffValue),
    ct:pal("Difficulty ~p\n", [Difficulty]),
    #{<<"prev_key_hash">> := DiffKeyHash} = DiffHeader,
    {ok, 200, #{<<"target">> := Target}} = get_key_block(DiffKeyHash),
    ?assertMatch(Difficulty, aec_pow:target_to_difficulty(Target)),

    %% Gas limit.
    ct:pal("Calling gas_limit\n"),
    {GLValue,_} = call_compute_func(NodeName, DPubkey, DPrivkey,
                                    EncodedContractPubkey,
                                    <<"gas_limit">>, <<"()">>),
    #{<<"value">> := GasLimit} = decode_data(<<"int">>, GLValue),
    ct:pal("Gas limit ~p\n", [GasLimit]),
    ?assertEqual(aec_governance:block_gas_limit(), GasLimit),

    aecore_suite_utils:mine_key_blocks(NodeName, 3),

    ct:pal("A Balances ~p, ~p, ~p\n", [ABal0,ABal1,get_balance(APubkey)]),
    ct:pal("B Balances ~p, ~p\n", [BBal0,get_balance(BPubkey)]),
    ct:pal("C Balances ~p, ~p\n", [CBal0,get_balance(CPubkey)]),
    ct:pal("D Balances ~p, ~p\n", [DBal0,get_balance(DPubkey)]),

    ok.

%% spend_test_contract(Config)
%%  Check the SpendTest contract.

spend_test_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),

    %% Create 2 new accounts, Alice and Bert.
    {APubkey,APrivkey,ATxHash} = new_account(1000000),
    {BPubkey,_BPrivkey,BTxHash} = new_account(2000000),

    ok = wait_for_tx_hash_on_chain(NodeName, ATxHash),
    ok = wait_for_tx_hash_on_chain(NodeName, BTxHash),

    %% Compile test contract "spend_test.aes"
    Code = compile_test_contract("spend_test"),

    %% Initialise contracts owned by Alice with balance set to 10000 and 20000.
    {EncodedC1Pubkey,DecodedC1Pubkey,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code,
                                <<"()">>, #{amount => 10000}),
    {EncodedC2Pubkey,DecodedC2Pubkey,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code,
                                <<"()">>, #{amount => 20000}),

    aecore_suite_utils:mine_key_blocks(NodeName, 3),

    %% Alice does all the operations on the contract and spends on Bert.
    %% Check the contract balances.
    {GB1Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                     EncodedC1Pubkey,
                                     <<"get_balance">>, <<"()">>),
    #{<<"value">> := 10000} = decode_data(<<"int">>, GB1Value),
    {GB2Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                     EncodedC2Pubkey,
                                     <<"get_balance">>, <<"()">>),
    #{<<"value">> := 20000} = decode_data(<<"int">>, GB2Value),

    %% Spend 15000 on to Bert.
    Sp1Arg = args_to_binary([BPubkey,15000]),
    {Sp1Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                     EncodedC2Pubkey,
                                     <<"spend">>, Sp1Arg),
    #{<<"value">> := 5000} = decode_data(<<"int">>, Sp1Value),

    aecore_suite_utils:mine_key_blocks(NodeName, 3),

    %% Check that contract spent it.
    GBO1Arg = args_to_binary([DecodedC2Pubkey]),
    {GBO1Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                      EncodedC1Pubkey,
                                      <<"get_balance_of">>, GBO1Arg),
    #{<<"value">> := 5000} = decode_data(<<"int">>, GBO1Value),

    %% Check that Bert got it.
    GBO2Arg = args_to_binary([BPubkey]),
    {GBO2Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                      EncodedC1Pubkey,
                                      <<"get_balance_of">>, GBO2Arg),
    #{<<"value">> := 2015000} = decode_data(<<"int">>, GBO2Value),

    %% Spend 6000 explicitly from contract 1 to Bert.
    SF1Arg = args_to_binary([DecodedC1Pubkey,BPubkey,6000]),
    {SF1Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                     EncodedC2Pubkey,
                                     <<"spend_from">>, SF1Arg),
    #{<<"value">> := 2021000} = decode_data(<<"int">>, SF1Value),

    aecore_suite_utils:mine_key_blocks(NodeName, 3),

    %% Check that Bert got it.
    GBO3Arg = args_to_binary([BPubkey]),
    {GBO3Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                      EncodedC1Pubkey,
                                      <<"get_balance_of">>, GBO3Arg),
    #{<<"value">> := 2021000} = decode_data(<<"int">>, GBO3Value),

    %% Check contract 2 balance.
    GBO4Arg = args_to_binary([DecodedC2Pubkey]),
    {GBO4Value,_} = call_compute_func(NodeName, APubkey, APrivkey,
                                      EncodedC1Pubkey,
                                      <<"get_balance_of">>, GBO4Arg),
    #{<<"value">> := 5000} = decode_data(<<"int">>, GBO4Value),

    ok.

%% dutch_auction_contract(Config)
%%  Check the DutchAuction contract. We use 3 accounts here, Alice for
%%  setting up the account, Carl as beneficiary and Bert as
%%  bidder. This makes it a bit easier to keep track of the values as
%%  we have gas loses as well.

dutch_auction_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey},
      acc_c := #{pub_key := CPubkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    _BBal0 = ensure_balance(BPubkey, 500000),
    _CBal0 = ensure_balance(CPubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "dutch_auction.aes"
    Code = compile_test_contract("dutch_auction"),

    %% Set auction start amount and decrease per mine and fee.
    StartAmt = 50000,
    Decrease = 500,
    Fee = 100,

    %% Initialise contract owned by Alice with Carl as benficiary.
    InitArgument = args_to_binary([CPubkey,StartAmt,Decrease]),
    {EncodedContractPubkey,_,InitReturn} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code, InitArgument),
    #{<<"height">> := Height0} = InitReturn,

    %% Mine 10 times to decrement value.
    {ok,_} = aecore_suite_utils:mine_key_blocks(NodeName, 10),

    _ABal1 = get_balance(APubkey),
    BBal1 = get_balance(BPubkey),
    CBal1 = get_balance(CPubkey),

    %% Call the contract bid function by Bert.
    {_,#{return := BidReturn}} =
        call_compute_func(NodeName, BPubkey, BPrivkey,
                          EncodedContractPubkey,
                          <<"bid">>, <<"()">>,
                          #{amount => 100000,fee => Fee}),
    #{<<"gas_used">> := GasUsed,<<"height">> := Height1} = BidReturn,

    %% Set the cost from the amount, decrease and diff in height.
    Cost = StartAmt - (Height1 - Height0) * Decrease,

    BBal2 = get_balance(BPubkey),
    CBal2 = get_balance(CPubkey),

    %% ct:pal("B Balances ~p, ~p, ~p\n", [BBal0,BBal1,BBal2]),
    %% ct:pal("Cost ~p, GasUsed ~p, Fee ~p\n", [Cost,GasUsed,Fee]),
    %% ct:pal("C Balances ~p, ~p, ~p\n", [CBal0,CBal1,CBal2]),

    %% Check that the balances are correct, don't forget the gas and the fee.
    BBal2 = BBal1 - Cost - GasUsed - Fee,
    CBal2 = CBal1 + Cost,

    ok.

%% fundme_contract(Config)
%%  Check the FundMe contract. We use 4 accounts here, Alice to set up
%%  the account, Bert and beneficiarya, and Carl and Diana as
%%  contributors.

fundme_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey},
      acc_c := #{pub_key := CPubkey,
                 priv_key := CPrivkey},
      acc_d := #{pub_key := DPubkey,
                 priv_key := DPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    BBal0 = ensure_balance(BPubkey, 500000),
    _CBal0 = ensure_balance(CPubkey, 500000),
    _DBal0 = ensure_balance(DPubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    %% Compile test contract "fundme.aes"
    Code = compile_test_contract("fundme"),

    %% Get the current height.
    {ok,200,#{<<"height">> := StartHeight}} = get_key_blocks_current_height(),

    %% Set deadline and goal.
    Deadline = StartHeight + 20,
    Goal = 150000,

    %% Initialise contract owned by Alice with Bert as benficiary.
    InitArg = args_to_binary([BPubkey,Deadline,Goal]),
    {EncodedContractPubkey,_,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code, InitArg),

    %% Let Carl and Diana contribute and check if we can withdraw early.
    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedContractPubkey,
                      <<"contribute">>, <<"()">>, #{<<"amount">> => 100000}),

    %% This should fail as we have not reached the goal.
    error_call_compute_func(NodeName, BPubkey, BPrivkey, EncodedContractPubkey,
                            <<"withdraw">>, <<"()">>),
    BBal1 = get_balance(BPubkey),

    call_compute_func(NodeName, DPubkey, DPrivkey, EncodedContractPubkey,
                      <<"contribute">>, <<"()">>, #{<<"amount">> => 100000}),

    %% This should fail as we have not reached the deadline.
    error_call_compute_func(NodeName, BPubkey, BPrivkey, EncodedContractPubkey,
                            <<"withdraw">>, <<"()">>),
    BBal2 = get_balance(BPubkey),

    %% Mine 10 times to get past deadline.
    {ok,_} = aecore_suite_utils:mine_key_blocks(NodeName, 10),

    %% Now withdraw the amount
    call_compute_func(NodeName, BPubkey, BPrivkey, EncodedContractPubkey,
                      <<"withdraw">>, <<"()">>),
    BBal3 = get_balance(BPubkey),

    ct:pal("BBalance ~p, ~p, ~p, ~p\n", [BBal0,BBal1,BBal2,BBal3]),

    ok.

%% erc20_token_contract(Config)

erc20_token_contract(Config) ->
    NodeName = proplists:get_value(node_name, Config),
    %% Get account information.
    #{acc_a := #{pub_key := APubkey,
                 priv_key := APrivkey},
      acc_b := #{pub_key := BPubkey,
                 priv_key := BPrivkey},
      acc_c := #{pub_key := CPubkey,
                 priv_key := CPrivkey},
      acc_d := #{pub_key := DPubkey,
                 priv_key := DPrivkey}} = proplists:get_value(accounts, Config),

    %% Make sure accounts have enough tokens.
    _ABal0 = ensure_balance(APubkey, 500000),
    BBal0 = ensure_balance(BPubkey, 500000),
    _CBal0 = ensure_balance(CPubkey, 500000),
    _DBal0 = ensure_balance(DPubkey, 500000),
    {ok,[_]} = aecore_suite_utils:mine_key_blocks(NodeName, 1),

    ContractString = aeso_test_utils:read_contract("erc20_token"),
    aeso_compiler:from_string(ContractString, []),

    %% Compile test contract "erc20_token.aes"
    Code = compile_test_contract("erc20_token"),

    %% Default values, 100000, 10, "Token Name", "TKN".
    Total = 100000,
    Decimals = 10,
    Name = <<"Token Name">>,
    Symbol = <<"TKN">>,

    %% Initialise contract owned by Alice.
    InitArg = args_to_binary([Total,Decimals,{string,Name},{string,Symbol}]),
    {EncodedContractPubkey,_,_} =
        create_compute_contract(NodeName, APubkey, APrivkey, Code, InitArg),

    %% Call funcion and decode value.
    CallDec = fun (Pubkey, Privkey, Func, Arg, Type) ->
                      call_func_decode(NodeName, Pubkey, Privkey,
                                       EncodedContractPubkey,
                                       Func, Arg, Type)
              end,

    %% Test state record fields.
    Total = CallDec(APubkey, APrivkey, <<"totalSupply">>, <<"()">>, <<"int">>),
    Decimals = CallDec(APubkey, APrivkey, <<"decimals">>, <<"()">>, <<"int">>),
    Name = CallDec(APubkey, APrivkey, <<"name">>, <<"()">>, <<"string">>),
    Symbol = CallDec(APubkey, APrivkey, <<"symbol">>, <<"()">>, <<"string">>),

    %% Setup balances for Bert to 20000 and Carl to 25000 and check balances.
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"transfer">>, args_to_binary([BPubkey,20000])),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"transfer">>, args_to_binary([CPubkey,25000])),
    55000 = CallDec(APubkey, APrivkey, <<"balanceOf">>,
                       args_to_binary([APubkey]), <<"int">>),
    20000 = CallDec(APubkey, APrivkey, <<"balanceOf">>,
                       args_to_binary([BPubkey]), <<"int">>),
    25000 = CallDec(APubkey, APrivkey, <<"balanceOf">>,
                       args_to_binary([CPubkey]), <<"int">>),
    0 = CallDec(APubkey, APrivkey, <<"balanceOf">>,
                args_to_binary([DPubkey]), <<"int">>),

    %% Bert and Carl approve transfering 15000 to Alice.
    call_compute_func(NodeName, BPubkey, BPrivkey, EncodedContractPubkey,
                      <<"approve">>, args_to_binary([APubkey,15000])),
    call_compute_func(NodeName, CPubkey, CPrivkey, EncodedContractPubkey,
                      <<"approve">>, args_to_binary([APubkey,15000])),

    %% Alice transfers 10000 from Bert and 15000 Carl to Diana.
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"transferFrom">>,
                      args_to_binary([BPubkey,DPubkey,10000])),
    call_compute_func(NodeName, APubkey, APrivkey, EncodedContractPubkey,
                      <<"transferFrom">>,
                      args_to_binary([CPubkey,DPubkey,15000])),

    %% Check the balances.
    10000 = CallDec(APubkey, APrivkey, <<"balanceOf">>,
                    args_to_binary([BPubkey]), <<"int">>),
    10000 = CallDec(APubkey, APrivkey, <<"balanceOf">>,
                    args_to_binary([CPubkey]), <<"int">>),
    25000 = CallDec(APubkey, APrivkey, <<"balanceOf">>,
                    args_to_binary([DPubkey]), <<"int">>),

    %% Print transfer and approval logs for final visual check.
    Transfer2 = CallDec(APubkey, APrivkey, <<"getTransferLog">>, <<"()">>,
                       <<"list((address,address,int))">>),
    Approval2 = CallDec(APubkey, APrivkey, <<"getApprovalLog">>, <<"()">>,
                       <<"list((address,address,int))">>),

    ct:pal("Transfer2 ~p\n", [Transfer2]),
    ct:pal("Approval2 ~p\n", [Approval2]),

    ok.

%% Internal access functions.

get_balance(Pubkey) ->
    Addr = aec_base58c:encode(account_pubkey, Pubkey),
    {ok,200,#{<<"balance">> := Balance}} = get_account_by_pubkey(Addr),
    Balance.

ensure_balance(Pubkey, NewBalance) ->
    Balance = get_balance(Pubkey),              %Get current balance
    if Balance >= NewBalance ->                 %Enough already, do nothing
            Balance;
       true ->
            %% Get more tokens from the miner.
            Fee = 1,
            Incr = NewBalance - Balance + Fee,  %Include the fee
            {ok,200,#{<<"tx">> := SpendTx}} =
                post_spend_tx(aec_base58c:encode(account_pubkey, Pubkey), Incr, Fee),
            SignedSpendTx = sign_tx(SpendTx),
            {ok, 200, _} = post_tx(SignedSpendTx),
            NewBalance
    end.

decode_data(Type, EncodedData) ->
    {ok,200,#{<<"data">> := DecodedData}} =
         get_contract_decode_data(#{'sophia-type' => Type,
                                    data => EncodedData}),
    DecodedData.

call_func_decode(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                 Function, Arg, Type) ->
    {Return,_} = call_compute_func(NodeName, Pubkey, Privkey,
                                   EncodedContractPubkey,
                                   Function, Arg),
    #{<<"value">> := Value} = decode_data(Type, Return),
    Value.

%% Contract interface functions.

%% compile_test_contract(FileName) -> Code.
%%  Compile a *test* contract file.

compile_test_contract(ContractFile) ->
    ContractString = aeso_test_utils:read_contract(ContractFile),
    SophiaCode = list_to_binary(ContractString),
    {ok, 200, #{<<"bytecode">> := Code}} = get_contract_bytecode(SophiaCode),
    Code.

%% create_compute_contract(NodeName, Pubkey, Privkey, Code, InitArgument) ->
%%     {EncodedContractPubkey,DecodedContractPubkey,InitReturn}.
%%  Create contract and mine blocks until in chain.

create_compute_contract(NodeName, Pubkey, Privkey, Code, InitArgument) ->
    create_compute_contract(NodeName, Pubkey, Privkey, Code, InitArgument, #{}).

create_compute_contract(NodeName, Pubkey, Privkey, Code, InitArgument, CallerSet) ->
    {ContractCreateTxHash,EncodedContractPubkey,DecodedContractPubkey} =
        contract_create_compute_tx(Pubkey, Privkey, Code, InitArgument, CallerSet),

    %% Mine blocks and check that it is in the chain.
    ok = wait_for_tx_hash_on_chain(NodeName, ContractCreateTxHash),
    ?assert(tx_in_chain(ContractCreateTxHash)),

    %% Get value of last call.
    {ok,200,InitReturn} = get_contract_call_object(ContractCreateTxHash),
    ct:pal("Init return ~p\n", [InitReturn]),

    {EncodedContractPubkey,DecodedContractPubkey,InitReturn}.

%% call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
%%                   Function, Arguments)
%% call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
%%                   Function, Arguments, CallerSet)
%%  Call contract function with arguments and mine blocks until in chain.

call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                  Function, Argument) ->
    call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                      Function, Argument, #{}).

call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                  Function, Argument, CallerSet) ->
    ContractCallTxHash =
        contract_call_compute_tx(Pubkey, Privkey, EncodedContractPubkey,
                                 Function, Argument, CallerSet),

    %% Mine blocks and check that it is in the chain.
    ok = wait_for_tx_hash_on_chain(NodeName, ContractCallTxHash),
    ?assert(tx_in_chain(ContractCallTxHash)),

    %% Get the call object and return value.
    {ok,200,CallReturn} = get_contract_call_object(ContractCallTxHash),
    ct:pal("Call return ~p\n", [CallReturn]),

    #{<<"return_type">> := <<"ok">>,<<"return_value">> := Value} = CallReturn,

    %% Get the block where the tx was included
    {ok, 200, #{<<"block_hash">> := BlockHash}} = get_tx(ContractCallTxHash),
    {ok, 200, BlockHeader} = get_micro_block_header(BlockHash),

    {Value, #{header => BlockHeader, return => CallReturn}}.

%% error_call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
%%                         Function, Arguments)
%% error_call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
%%                         Function, Arguments, CallerSet)

error_call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                        Function, Argument) ->
    error_call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                            Function, Argument, #{}).

error_call_compute_func(NodeName, Pubkey, Privkey, EncodedContractPubkey,
                        Function, Argument, CallerSet) ->
    ContractCallTxHash =
        contract_call_compute_tx(Pubkey, Privkey, EncodedContractPubkey,
                                 Function, Argument, CallerSet),

    %% Mine blocks and check that it is in the chain.
    ok = wait_for_tx_hash_on_chain(NodeName, ContractCallTxHash),
    ?assert(tx_in_chain(ContractCallTxHash)),

    %% Get the call object and return value.
    {ok,200,CallReturn} = get_contract_call_object(ContractCallTxHash),
    ct:pal("Call return ~p\n", [CallReturn]),

    #{<<"return_type">> := <<"error">>,<<"return_value">> := Value} = CallReturn,
    {Value,CallReturn}.

%% contract_create_compute_tx(Pubkey, Privkey, Code, EncodedInitData) ->
%%     contract_create_compute_tx(Pubkey, Privkey, Code, EncodedInitData, #{}).

contract_create_compute_tx(Pubkey, Privkey, Code, InitArgument, CallerSet) ->
    Address = aec_base58c:encode(account_pubkey, Pubkey),
    %% Generate a nonce.
    {ok,200,#{<<"nonce">> := Nonce0}} = get_account_by_pubkey(Address),
    Nonce = Nonce0 + 1,

    %% The default init contract.
    ContractInitEncoded0 = #{ owner_id => Address,
                              code => Code,
                              vm_version => 1,  %?AEVM_01_Sophia_01
                              deposit => 2,
                              amount => 0,      %Initial balance
                              gas => 20000,     %May need a lot of gas
                              gas_price => 1,
                              fee => 1,
                              nonce => Nonce,
                              arguments => InitArgument,
                              payload => <<"create contract">>},
    ContractInitEncoded = maps:merge(ContractInitEncoded0, CallerSet),
    sign_and_post_create_compute_tx(Privkey, ContractInitEncoded).

%% contract_call_compute_tx(Pubkey, Privkey, EncodedContractPubkey,
%%                          Function, Argument) ->
%%     contract_call_compute_tx(Pubkey, Privkey, EncodedContractPubkey,
%%                              Function, Argument, #{}).

contract_call_compute_tx(Pubkey, Privkey, EncodedContractPubkey,
                         Function, Argument, CallerSet) ->
    Address = aec_base58c:encode(account_pubkey, Pubkey),
    %% Generate a nonce.
    {ok,200,#{<<"nonce">> := Nonce0}} = get_account_by_pubkey(Address),
    Nonce = Nonce0 + 1,

    ContractCallEncoded0 = #{ caller_id => Address,
                              contract_id => EncodedContractPubkey,
                              vm_version => 1,  %?AEVM_01_Sophia_01
                              amount => 0,
                              gas => 50000,     %May need a lot of gas
                              gas_price => 1,
                              fee => 1,
                              nonce => Nonce,
                              function => Function,
                              arguments => Argument,
                              payload => <<"call compute function">> },
    ContractCallEncoded = maps:merge(ContractCallEncoded0, CallerSet),
    sign_and_post_call_compute_tx(Privkey, ContractCallEncoded).

%% ============================================================
%% HTTP Requests
%% Note that some are internal and some are external!
%% ============================================================

get_top() ->
    Host = external_address(),
    http_request(Host, get, "blocks/top", []).

get_micro_block_header(Hash) ->
    Host = external_address(),
    http_request(Host, get,
                 "micro-blocks/hash/"
                 ++ binary_to_list(Hash)
                 ++ "/header", []).

get_key_block(Hash) ->
    Host = external_address(),
    http_request(Host, get,
                 "key-blocks/hash/"
                 ++ binary_to_list(Hash), []).

get_key_blocks_current_height() ->
    Host = external_address(),
    http_request(Host, get, "key-blocks/current/height", []).

get_key_block_at_height(Height) ->
    Host = external_address(),
    http_request(Host, get, "key-blocks/height/" ++ integer_to_list(Height), []).

get_contract_bytecode(SourceCode) ->
    Host = internal_address(),
    http_request(Host, post, "debug/contracts/code/compile",
                 #{ <<"code">> => SourceCode, <<"options">> => <<>> }).

%% get_contract_create(Data) ->
%%     Host = internal_address(),
%%     http_request(Host, post, "debug/contracts/create", Data).

get_contract_create_compute(Data) ->
    Host = internal_address(),
    http_request(Host, post, "debug/contracts/create/compute", Data).

%% get_contract_call(Data) ->
%%     Host = internal_address(),
%%     http_request(Host, post, "debug/contracts/call", Data).

get_contract_call_compute(Data) ->
    Host = internal_address(),
    http_request(Host, post, "debug/contracts/call/compute", Data).

get_contract_decode_data(Request) ->
    Host = internal_address(),
    http_request(Host, post, "debug/contracts/code/decode-data", Request).

get_contract_call_object(TxHash) ->
    Host = external_address(),
    http_request(Host, get, "transactions/"++binary_to_list(TxHash)++"/info", []).

get_tx(TxHash) ->
    Host = external_address(),
    http_request(Host, get, "transactions/" ++ binary_to_list(TxHash), []).

post_spend_tx(RecipientId, Amount, Fee) ->
    {ok, Sender} = rpc(aec_keys, pubkey, []),
    SenderId = aec_base58c:encode(account_pubkey, Sender),
    post_spend_tx(SenderId, RecipientId, Amount, Fee, <<"post spend tx">>).

post_spend_tx(SenderId, RecipientId, Amount, Fee, Payload) ->
    Host = internal_address(),
    http_request(Host, post, "debug/transactions/spend",
                 #{sender_id => SenderId,
                   recipient_id => RecipientId,
                   amount => Amount,
                   fee => Fee,
                   payload => Payload}).

get_account_by_pubkey(Id) ->
    Host = external_address(),
    http_request(Host, get, "accounts/" ++ http_uri:encode(Id), []).

post_tx(TxSerialized) ->
    Host = external_address(),
    http_request(Host, post, "transactions", #{tx => TxSerialized}).

sign_tx(Tx) ->
    {ok, TxDec} = aec_base58c:safe_decode(transaction, Tx),
    UnsignedTx = aetx:deserialize_from_binary(TxDec),
    {ok, SignedTx} = rpc(aec_keys, sign_tx, [UnsignedTx]),
    aec_base58c:encode(transaction, aetx_sign:serialize_to_binary(SignedTx)).

%% ============================================================
%% private functions
%% ============================================================
rpc(Mod, Fun, Args) ->
    rpc(?NODE, Mod, Fun, Args).

rpc(Node, Mod, Fun, Args) ->
    rpc:call(aecore_suite_utils:node_name(Node), Mod, Fun, Args, 5000).

external_address() ->
    Port = rpc(aeu_env, user_config_or_env,
              [ [<<"http">>, <<"external">>, <<"port">>],
                aehttp, [external, port], 8043]),
    "http://127.0.0.1:" ++ integer_to_list(Port).     % good enough for requests

internal_address() ->
    Port = rpc(aeu_env, user_config_or_env,
              [ [<<"http">>, <<"internal">>, <<"port">>],
                aehttp, [internal, port], 8143]),
    "http://127.0.0.1:" ++ integer_to_list(Port).

http_request(Host, get, Path, Params) ->
    URL = binary_to_list(
            iolist_to_binary([Host, "/v2/", Path, encode_get_params(Params)])),
    ct:log("GET ~p", [URL]),
    R = httpc_request(get, {URL, []}, [], []),
    process_http_return(R);
http_request(Host, post, Path, Params) ->
    URL = binary_to_list(iolist_to_binary([Host, "/v2/", Path])),
    {Type, Body} = case Params of
                       Map when is_map(Map) ->
                           %% JSON-encoded
                           {"application/json", jsx:encode(Params)};
                       [] ->
                           {"application/x-www-form-urlencoded",
                            http_uri:encode(Path)}
                   end,
    %% lager:debug("Type = ~p; Body = ~p", [Type, Body]),
    ct:log("POST ~p, type ~p, Body ~p", [URL, Type, Body]),
    R = httpc_request(post, {URL, [], Type, Body}, [], []),
    process_http_return(R).

httpc_request(Method, Request, HTTPOptions, Options) ->
    httpc_request(Method, Request, HTTPOptions, Options, test_browser).

httpc_request(Method, Request, HTTPOptions, Options, Profile) ->
    {ok, Pid} = inets:start(httpc, [{profile, Profile}], stand_alone),
    Response = httpc:request(Method, Request, HTTPOptions, Options, Pid),
    ok = gen_server:stop(Pid, normal, infinity),
    Response.

encode_get_params(#{} = Ps) ->
    encode_get_params(maps:to_list(Ps));
encode_get_params([{K,V}|T]) ->
    ["?", [str(K),"=",uenc(V)
           | [["&", str(K1), "=", uenc(V1)]
              || {K1, V1} <- T]]];
encode_get_params([]) ->
    [].

str(A) when is_atom(A) ->
    str(atom_to_binary(A, utf8));
str(S) when is_list(S); is_binary(S) ->
    S.

uenc(I) when is_integer(I) ->
    uenc(integer_to_list(I));
uenc(V) ->
    http_uri:encode(V).

process_http_return(R) ->
    case R of
        {ok, {{_, ReturnCode, _State}, _Head, Body}} ->
            try
                ct:log("Return code ~p, Body ~p", [ReturnCode, Body]),
                Result = case iolist_to_binary(Body) of
                             <<>> -> #{};
                             BodyB ->
                                 jsx:decode(BodyB, [return_maps])
                         end,
                {ok, ReturnCode, Result}
            catch
                error:E ->
                    {error, {parse_error, [E, erlang:get_stacktrace()]}}
            end;
        {error, _} = Error ->
            Error
    end.

new_account(Balance) ->
    {Pubkey,Privkey} = generate_key_pair(),
    Fee = 1,
    {ok, 200, #{<<"tx">> := SpendTx}} =
        post_spend_tx(aec_base58c:encode(account_pubkey, Pubkey), Balance, Fee),
    SignedSpendTx = sign_tx(SpendTx),
    {ok, 200, #{<<"tx_hash">> := SpendTxHash}} = post_tx(SignedSpendTx),
    {Pubkey,Privkey,SpendTxHash}.

%% spend_tokens(SenderPubkey, SenderPrivkey, Recipient, Amount, Fee) ->
%% spend_tokens(SenderPubkey, SenderPrivkey, Recipient, Amount, Fee, CallerSet) ->
%%     TxHash
%%  This is based on post_correct_tx/1 in aehttp_integration_SUITE.

spend_tokens(SenderPub, SenderPriv, Recip, Amount, Fee) ->
    DefaultSet = #{ttl => 0},                   %Defaut fields set by caller
    spend_tokens(SenderPub, SenderPriv, Recip, Amount, Fee, DefaultSet).

spend_tokens(SenderPub, SenderPriv, Recip, Amount, Fee, CallerSet) ->
    %% Generate a nonce.
    Address = aec_base58c:encode(account_pubkey, SenderPub),
    {ok,200,#{<<"nonce">> := Nonce0}} = get_account_by_pubkey(Address),
    Nonce = Nonce0 + 1,

    Params0 = #{sender_id => aec_id:create(account, SenderPub),
                recipient_id => aec_id:create(account, Recip),
                amount => Amount,
                fee => Fee,
                nonce => Nonce,
                payload => <<"spend tokens">>},
    Params1 = maps:merge(Params0, CallerSet),   %Set caller defaults
    {ok, UnsignedTx} = aec_spend_tx:new(Params1),
    SignedTx = aec_test_utils:sign_tx(UnsignedTx, SenderPriv),
    SerializedTx = aetx_sign:serialize_to_binary(SignedTx),
    %% Check that we get the correct hash.
    TxHash = aec_base58c:encode(tx_hash, aetx_sign:hash(SignedTx)),
    EncodedSerializedTx = aec_base58c:encode(transaction, SerializedTx),
    {ok, 200, #{<<"tx_hash">> := TxHash}} = post_tx(EncodedSerializedTx),
    TxHash.

sign_and_post_create_compute_tx(Privkey, CreateEncoded) ->
    {ok,200,#{<<"tx">> := EncodedUnsignedTx,
              <<"contract_id">> := EncodedPubkey}} =
        get_contract_create_compute(CreateEncoded),
    {ok,DecodedPubkey} = aec_base58c:safe_decode(contract_pubkey,
                                                 EncodedPubkey),
    TxHash = sign_and_post_tx(Privkey, EncodedUnsignedTx),
    {TxHash,EncodedPubkey,DecodedPubkey}.

sign_and_post_call_compute_tx(Privkey, CallEncoded) ->
    {ok,200,#{<<"tx">> := EncodedUnsignedTx}} =
        get_contract_call_compute(CallEncoded),
    sign_and_post_tx(Privkey, EncodedUnsignedTx).

sign_and_post_tx(PrivKey, EncodedUnsignedTx) ->
    {ok,SerializedUnsignedTx} = aec_base58c:safe_decode(transaction,
                                                        EncodedUnsignedTx),
    UnsignedTx = aetx:deserialize_from_binary(SerializedUnsignedTx),
    SignedTx = aec_test_utils:sign_tx(UnsignedTx, PrivKey),
    SerializedTx = aetx_sign:serialize_to_binary(SignedTx),
    SendTx = aec_base58c:encode(transaction, SerializedTx),
    {ok,200,#{<<"tx_hash">> := TxHash}} = post_tx(SendTx),
    TxHash.

tx_in_chain(TxHash) ->
    case get_tx(TxHash) of
        {ok, 200, #{<<"block_hash">> := <<"none">>}} ->
            ct:log("Tx not mined, but in mempool"),
            false;
        {ok, 200, #{<<"block_hash">> := _}} -> true;
        {ok, 404, _} -> false
    end.

wait_for_tx_hash_on_chain(Node, TxHash) ->
    case tx_in_chain(TxHash) of
        true -> ok;
        false ->
            case aecore_suite_utils:mine_blocks_until_tx_on_chain(Node, TxHash, 10) of
                {ok, _Blocks} -> ok;
                {error, _Reason} -> did_not_mine
            end
    end.

%% make_params(L) ->
%%     make_params(L, []).

%% make_params([], Accum) ->
%%     maps:from_list(Accum);
%% make_params([H | T], Accum) when is_map(H) ->
%%     make_params(T, maps:to_list(H) ++ Accum);
%% make_params([{K, V} | T], Accum) ->
%%     make_params(T, [{K, V} | Accum]).

generate_key_pair() ->
    #{ public := Pubkey, secret := Privkey } = enacl:sign_keypair(),
    {Pubkey, Privkey}.

%% args_to_binary(Args) -> binary_string().
%%  Take a list of arguments in "erlang format" and generate an
%%  argument binary string. Strings are handled naively now.

args_to_binary(Args) ->
    %% ct:pal("Args ~tp\n", [Args]),
    BinArgs = list_to_binary([$(,args_to_list(Args),$)]),
    %% ct:pal("BinArgs ~tp\n", [BinArgs]),
    BinArgs.

args_to_list([A]) -> [arg_to_list(A)];          %The last one
args_to_list([A1|Rest]) ->
    [arg_to_list(A1),$,|args_to_list(Rest)];
args_to_list([]) -> [].

%%arg_to_list(<<N:256>>) -> integer_to_list(N);
arg_to_list(N) when is_integer(N) -> integer_to_list(N);
arg_to_list(B) when is_binary(B) ->             %A key
    binary_to_list(aeu_hex:hexstring_encode(B));
arg_to_list({string,S}) -> ["\"",S,"\""];
arg_to_list(T) when is_tuple(T) ->
    [$(,args_to_list(tuple_to_list(T)),$)];
arg_to_list(M) when is_map(M) ->
    [${,map_to_list(maps:to_list(M)),$}].

map_to_list([{K,V}]) -> [$[,arg_to_list(K),"] = ",arg_to_list(V)];
map_to_list([{K,V},Fields]) ->
    [$[,arg_to_list(K),"] = ",arg_to_list(V),$,|map_to_list(Fields)];
map_to_list([]) -> [].
