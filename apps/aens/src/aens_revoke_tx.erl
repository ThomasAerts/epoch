%%%=============================================================================
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%%    Module defining the Naming System revoke transaction
%%% @end
%%%=============================================================================
-module(aens_revoke_tx).

-behavior(aetx).

%% Behavior API
-export([new/1,
         type/0,
         fee/1,
         gas/1,
         ttl/1,
         nonce/1,
         origin/1,
         check/3,
         process/3,
         signers/2,
         version/0,
         serialization_template/1,
         serialize/1,
         deserialize/2,
         for_client/1
        ]).

%%%===================================================================
%%% Types
%%%===================================================================

-define(NAME_REVOKE_TX_VSN, 1).
-define(NAME_REVOKE_TX_TYPE, name_revoke_tx).

-record(ns_revoke_tx, {
          account_id :: aec_id:id(),
          nonce      :: integer(),
          name_id    :: aec_id:id(),
          fee        :: integer(),
          ttl        :: aetx:tx_ttl()
         }).

-opaque tx() :: #ns_revoke_tx{}.

-export_type([tx/0]).

%%%===================================================================
%%% Behaviour API
%%%===================================================================

-spec new(map()) -> {ok, aetx:tx()}.
new(#{account_id := AccountId,
      nonce      := Nonce,
      name_id    := NameId,
      fee        := Fee} = Args) ->
    account = aec_id:specialize_type(AccountId),
    name    = aec_id:specialize_type(NameId),
    Tx = #ns_revoke_tx{account_id = AccountId,
                       nonce      = Nonce,
                       name_id    = NameId,
                       fee        = Fee,
                       ttl        = maps:get(ttl, Args, 0)},
    {ok, aetx:new(?MODULE, Tx)}.

-spec type() -> atom().
type() ->
    ?NAME_REVOKE_TX_TYPE.

-spec fee(tx()) -> integer().
fee(#ns_revoke_tx{fee = Fee}) ->
    Fee.

-spec gas(tx()) -> non_neg_integer().
gas(#ns_revoke_tx{}) ->
    aec_governance:tx_base_gas().

-spec ttl(tx()) -> aetx:tx_ttl().
ttl(#ns_revoke_tx{ttl = TTL}) ->
    TTL.

-spec nonce(tx()) -> non_neg_integer().
nonce(#ns_revoke_tx{nonce = Nonce}) ->
    Nonce.

-spec origin(tx()) -> aec_keys:pubkey().
origin(#ns_revoke_tx{} = Tx) ->
    account_pubkey(Tx).

-spec check(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()} | {error, term()}.
check(#ns_revoke_tx{nonce = Nonce,
                    fee   = Fee} = Tx,
      Trees,_Env) ->
    AccountPubKey = account_pubkey(Tx),
    NameHash = name_hash(Tx),

    Checks =
        [fun() -> aetx_utils:check_account(AccountPubKey, Trees, Nonce, Fee) end,
         fun() -> aens_utils:check_name_claimed_and_owned(NameHash, AccountPubKey, Trees) end],

    case aeu_validation:run(Checks) of
        ok              -> {ok, Trees};
        {error, Reason} -> {error, Reason}
    end.

-spec process(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()}.
process(#ns_revoke_tx{fee = Fee, nonce = Nonce} = Tx,
        Trees0, Env) ->
    Height = aetx_env:height(Env),
    AccountPubKey = account_pubkey(Tx),
    NameHash = name_hash(Tx),
    AccountsTree0 = aec_trees:accounts(Trees0),
    NamesTree0 = aec_trees:ns(Trees0),

    Account0 = aec_accounts_trees:get(AccountPubKey, AccountsTree0),
    {ok, Account1} = aec_accounts:spend(Account0, Fee, Nonce),
    AccountsTree1 = aec_accounts_trees:enter(Account1, AccountsTree0),

    TTL = aec_governance:name_protection_period(),
    Name0 = aens_state_tree:get_name(NameHash, NamesTree0),
    Name1 = aens_names:revoke(Name0, TTL, Height),
    NamesTree1 = aens_state_tree:enter_name(Name1, NamesTree0),

    Trees1 = aec_trees:set_accounts(Trees0, AccountsTree1),
    Trees2 = aec_trees:set_ns(Trees1, NamesTree1),

    {ok, Trees2}.

-spec signers(tx(), aec_trees:trees()) -> {ok, [aec_keys:pubkey()]}.
signers(#ns_revoke_tx{} = Tx, _) ->
    {ok, [account_pubkey(Tx)]}.

-spec serialize(tx()) -> {integer(), [{atom(), term()}]}.
serialize(#ns_revoke_tx{account_id = AccountId,
                        nonce      = Nonce,
                        name_id    = NameId,
                        fee        = Fee,
                        ttl        = TTL}) ->
    {version(),
     [ {account_id, AccountId}
     , {nonce, Nonce}
     , {name_id, NameId}
     , {fee, Fee}
     , {ttl, TTL}
     ]}.

-spec deserialize(Vsn :: integer(), list({atom(), term()})) -> tx().
deserialize(?NAME_REVOKE_TX_VSN,
            [ {account_id, AccountId}
            , {nonce, Nonce}
            , {name_id, NameId}
            , {fee, Fee}
            , {ttl, TTL}]) ->
    account = aec_id:specialize_type(AccountId),
    name    = aec_id:specialize_type(NameId),
    #ns_revoke_tx{account_id = AccountId,
                  nonce      = Nonce,
                  name_id    = NameId,
                  fee        = Fee,
                  ttl        = TTL}.

serialization_template(?NAME_REVOKE_TX_VSN) ->
    [ {account_id, id}
    , {nonce, int}
    , {name_id, id}
    , {fee, int}
    , {ttl, int}
    ].

-spec for_client(tx()) -> map().
for_client(#ns_revoke_tx{account_id = AccountId,
                         nonce      = Nonce,
                         name_id    = NameId,
                         fee        = Fee,
                         ttl        = TTL}) ->
    #{<<"account_id">> => aec_base58c:encode(id_hash, AccountId),
      <<"nonce">>      => Nonce,
      <<"name_id">>    => aec_base58c:encode(id_hash, NameId),
      <<"fee">>        => Fee,
      <<"ttl">>        => TTL}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

account_pubkey(#ns_revoke_tx{account_id = AccountId}) ->
    aec_id:specialize(AccountId, account).

name_hash(#ns_revoke_tx{name_id = NameId}) ->
    aec_id:specialize(NameId, name).

version() ->
    ?NAME_REVOKE_TX_VSN.

