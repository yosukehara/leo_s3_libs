%%======================================================================
%%
%% Leo S3-Libs
%%
%% Copyright (c) 2012 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% Leo Libs - Auth
%% @doc
%% @end
%%======================================================================
-module(leo_s3_auth).

-author('Yosuke Hara').

-include("leo_s3_auth.hrl").
-include("leo_s3_endpoint.hrl").
-include("leo_s3_libs.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start/2, create_credential_table/2,
         update_providers/1,
         create_key/1, get_credential/1, has_credential/1, has_credential/2,
         authenticate/3, get_signature/2
        ]).


-record(auth_params, {access_key_id     :: binary(),
                      secret_access_key :: binary(),
                      signature         :: binary(),
                      sign_params       :: #sign_params{},
                      auth_info         :: #auth_info{}
                     }).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Launch or create  Mnesia/ETS
%%
-spec(start(master | slave, list()) ->
             ok).
start(slave, Provider) ->
    catch ets:new(?AUTH_TABLE, [named_table, set, public, {read_concurrency, true}]),
    catch ets:new(?AUTH_INFO,  [named_table, set, public, {read_concurrency, true}]),

    case Provider of
        [] ->
            void;
        _ ->
            ok = setup(ets, Provider)
    end,
    ok;

start(master, Provider) ->
    catch ets:new(?AUTH_INFO,  [named_table, set, public, {read_concurrency, true}]),
    ok = setup(mnesia, Provider),
    ok.

%% @doc update_providers(slave only)
%%
-spec(update_providers(list()) ->
             ok).
update_providers(Provider) ->
    true = ets:insert(?AUTH_INFO, {1, #auth_info{db       = ets,
                                                 provider = Provider}}),
    ok.

%% @doc Create credential table(mnesia)
%%
-spec(create_credential_table(ram_copies|disc_copies, list()) ->
             ok).
create_credential_table(Mode, Nodes) ->
    catch application:start(mnesia),
    {atomic, ok} =
        mnesia:create_table(
          ?AUTH_TABLE,
          [{Mode, Nodes},
           {type, set},
           {record_name, credential},
           {attributes, record_info(fields, credential)},
           {user_properties,
            [{access_key_id,     {binary, undefined},  false, primary,   undefined, identity,  binary},
             {secret_access_key, {binary, undefined},  false, undefined, undefined, undefined, binary},
             {user_id,           {binary, undefined},  false, undefined, undefined, undefined, binary},
             {created_at,        {integer, undefined}, false, undefined, undefined, undefined, integer}
            ]}
          ]),
    ok.


%% @doc Generate access-key-id and secret-access-key
%%
-spec(create_key(string()) ->
             {ok, list()} | {error, any()}).
create_key(UserId) ->
    Clock = integer_to_list(leo_date:clock()),

    case get_auth_info() of
        {ok, #auth_info{db = ets}} ->
            {error, not_generated};
        {ok, #auth_info{db = mnesia}} ->
            Digest0 = list_to_binary(string:sub_string(
                                       leo_hex:binary_to_hex(
                                         crypto:hash(sha, term_to_binary({UserId, Clock}))),1,20)),
            Digest1 = list_to_binary(leo_hex:binary_to_hex(
                                       crypto:hash(sha,
                                         list_to_binary(lists:append([UserId,"/",Clock]))))),
            create_key1(UserId, Digest0, Digest1);
        [] ->
            {error, not_initialized};
        not_found ->
            {error, not_initialized};
        {'EXIT', Cause} ->
            {error, Cause}
    end.


%% @doc Retrieve a credential from internal-db
%%
-spec(get_credential(binary()) ->
             {ok, #credential{}} | not_found | {error, any()}).
get_credential(AccessKeyId) ->
    leo_s3_libs_data_handler:lookup({mnesia, ?AUTH_TABLE}, AccessKeyId).


%% @doc Has a credential into the master-nodes?
%%
-spec(has_credential(binary()) ->
             true | false).
has_credential(AccessKeyId) ->
    case get_credential(AccessKeyId) of
        {ok, _Credential} ->
            true;
        _ ->
            false
    end.

-spec(has_credential(list(), binary()) ->
             true | false).
has_credential(MasterNodes, AccessKey) ->
    Ret = lists:foldl(
            fun(Node, false) ->
                    RPCKey = rpc:async_call(Node, leo_s3_auth, has_credential, [AccessKey]),
                    case rpc:nb_yield(RPCKey, ?DEF_REQ_TIMEOUT) of
                        {value, true} ->
                            true;
                        _Error ->
                            false
                    end;
               (_,  true) ->
                    true
            end, false, MasterNodes),
    Ret.


%% @doc Authenticate
%%
-spec(authenticate(binary(), #sign_params{}, boolean()) ->
             {ok, binary()} | {error, any()}).
authenticate(Authorization, #sign_params{uri = <<"/">>} = SignParams, _IsCreateBucketOp) ->
    [AccWithAWS,Signature|_] = binary:split(Authorization, <<":">>),
    <<"AWS ", AccessKeyId/binary>> = AccWithAWS,
    authenticate1(#auth_params{access_key_id = AccessKeyId,
                               signature     = Signature,
                               sign_params   = SignParams});

authenticate(Authorization, #sign_params{bucket = Bucket} = SignParams, IsCreateBucketOp) ->
    [AccWithAWS,Signature|_] = binary:split(Authorization, <<":">>),
    <<"AWS ", AccessKeyId/binary>> = AccWithAWS,
    case {leo_s3_bucket:head(AccessKeyId, Bucket), IsCreateBucketOp} of
        {ok, false} ->
            authenticate1(#auth_params{access_key_id = AccessKeyId,
                                       signature     = Signature,
                                       sign_params   = SignParams#sign_params{bucket = Bucket}});
        {not_found, true} ->
            authenticate1(#auth_params{access_key_id = AccessKeyId,
                                       signature     = Signature,
                                       sign_params   = SignParams#sign_params{bucket = Bucket}});
        _Other ->
            {error, unmatch}
    end.


%% @doc Generate a signature.
%% @private
-define(SUB_RESOURCES, [<<"acl">>, <<"lifecycle">>, <<"location">>, <<"logging">>, <<"notification">>, <<"partNumber">>, <<"policy">>, <<"requestPayment">>, <<"torrent">>, <<"uploadId">>, <<"uploads">>, <<"versionid">>, <<"versioning">>, <<"versions">>, <<"website">>, <<"response-content-type">>, <<"response-content-language">>, <<"response-expires">>, <<"response-cache-control">>, <<"response-content-disposition">>, <<"response-content-encoding">>]).

-spec(get_signature(binary(), #sign_params{}) ->
             binary()).
get_signature(SecretAccessKey, SignParams) ->
    #sign_params{http_verb    = HTTPVerb,
                 content_md5  = ETag,
                 content_type = ContentType,
                 date         = Date0,
                 bucket       = Bucket0,
                 uri          = URI0,
                 query_str    = QueryStr,
                 amz_headers  = AmzHeaders
                } = SignParams,

    Date1   = auth_date(Date0, AmzHeaders),
    Sub0    = auth_resources(AmzHeaders),
    Sub1    = auth_sub_resources(QueryStr),
    Bucket1 = auth_bucket(URI0, Bucket0, QueryStr),
    URI1    = auth_uri(Bucket0, URI0),
    BinToSign = <<HTTPVerb/binary,    "\n",
                  ETag/binary,        "\n",
                  ContentType/binary, "\n",
                  Date1/binary,       "\n",
                  Sub0/binary, Bucket1/binary, URI1/binary, Sub1/binary>>,
    %% ?debugVal(binary_to_list(BinToSign)),
    Context = crypto:hmac_init(sha, SecretAccessKey),
    Context2 = crypto:hmac_update(Context, BinToSign),
    Mac = crypto:hmac_final(Context2),
    Signature = base64:encode(Mac),
    %% ?debugVal(Signature),
    Signature.


%%--------------------------------------------------------------------
%%% INTERNAL FUNCTIONS
%%--------------------------------------------------------------------
%% @doc Setup
%% @private
-spec(setup(ets|mnesia, list()) ->
             ok).
setup(DB, Provider) ->
    true = ets:insert(?AUTH_INFO, {1, #auth_info{db       = DB,
                                                 provider = Provider}}),
    ok.


%% @doc Generate a credential
%% @private
-spec(create_key1(string(), binary(), binary()) ->
             {ok, list()} | {error, any()}).
create_key1(UserId, Digest0, Digest1) ->
    case leo_s3_libs_data_handler:lookup({mnesia, ?AUTH_TABLE}, Digest0) of
        {ok, _} ->
            create_key(UserId);
        not_found ->
            _ = leo_s3_libs_data_handler:insert(
                  {mnesia, ?AUTH_TABLE}, {[], #credential{access_key_id     = Digest0,
                                                          secret_access_key = Digest1,
                                                          created_at        = leo_date:now()}}),
            {ok, [{access_key_id,     Digest0},
                  {secret_access_key, Digest1}]};
        _ ->
            {error, not_initialized}
    end.


%% @doc Authenticate#1
%% @private
-spec(authenticate1(#auth_params{}) ->
             {ok, binary()} | {error, any()}).
authenticate1(AuthParams) ->
    case get_auth_info() of
        {ok, AuthInfo} ->
            authenticate2(AuthParams#auth_params{auth_info = AuthInfo});
        _ ->
            {error, not_initialized}
    end.

%% @doc Authenticate#2
%% @private
-spec(authenticate2(#auth_params{}) ->
             {ok, binary()} | {error, any()}).
authenticate2(AuthParams) ->
    #auth_params{access_key_id = AccessKeyId,
                 auth_info     = #auth_info{db = DB}} = AuthParams,

    case leo_s3_libs_data_handler:lookup({DB, ?AUTH_TABLE}, AccessKeyId) of
        {ok, #credential{secret_access_key = SecretAccessKey}} ->
            authenticate3(AuthParams#auth_params{secret_access_key = SecretAccessKey});
        not_found when DB == ets ->
            authenticate4(AuthParams);
        {error, Cause} ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING}, {function, "authenticate2/1"},
                                    {line, ?LINE}, {body, Cause}]),
            {error, unmatch}
    end.


%% @doc Authenticate#3
%% @private
-spec(authenticate3(#auth_params{}) ->
             {ok, binary()} | {error, any()}).
authenticate3(#auth_params{secret_access_key = SecretAccessKey,
                           access_key_id     = AccessKeyId,
                           signature         = Signature,
                           sign_params       = SignParams}) ->
    %% ?debugVal({Signature, SignParams}),

    case get_signature(SecretAccessKey, SignParams) of
        Signature ->
            {ok, AccessKeyId};
        WrongSig ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING}, {function, "authenticate3/1"},
                                    {line, ?LINE}, {body, WrongSig}]),
            {error, unmatch}
    end.


%% @doc Authenticate#4
%% @private
-spec(authenticate4(#auth_params{}) ->
             {ok, binary()} | {error, any()}).
authenticate4(AuthParams) ->
    #auth_params{access_key_id = AccessKeyId,
                 auth_info     = #auth_info{provider = Provider}} = AuthParams,

    %% Retrieve auth-info from a provider
    %%
    case lists:foldl(fun(Node, [] = Acc) ->
                             RPCKey = rpc:async_call(Node, leo_s3_auth, get_credential, [AccessKeyId]),
                             case rpc:nb_yield(RPCKey, ?DEF_REQ_TIMEOUT) of
                                 {value, {ok, Value}} ->
                                     Value;
                                 _ ->
                                     Acc
                             end;
                        (_Node, Acc) ->
                             Acc
                     end, [], Provider) of
        [] ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING}, {function, "authenticate4/1"},
                                    {line, ?LINE}, {body, "get_credential rpc failed"}]),
            {error, unmatch};
        Credential ->
            _ = leo_s3_libs_data_handler:insert({ets, ?AUTH_TABLE},{AccessKeyId, Credential}),
            authenticate3(
              AuthParams#auth_params{
                secret_access_key = Credential#credential.secret_access_key})
    end.


%% @doc Retrieve db-type from ETS
%% @private
-spec(get_auth_info() ->
             {ok, ets | mnesia} | not_found).
get_auth_info() ->
    case catch ets:lookup(leo_s3_auth_info, 1) of
        [{_, AuthInfo}|_] ->
            {ok, AuthInfo};
        _ ->
            not_found
    end.


%% @doc Retrieve date
%% @private
auth_date(Date0, CannonocalizedResources) ->
    case lists:keysearch("x-amz-date", 1, CannonocalizedResources) of
        {value, _} ->
            <<>>;
        false ->
            << Date0/binary >>
    end.


%% @doc Retrieve a bucket from string
%% @private
%% auth_bucket("/",_Bucket, []) -> [];
%% auth_bucket(<<"/">>, Bucket,  _) -> << <<"/">>, Bucket >>;
auth_bucket(_, <<>>,  _) -> <<>>;
auth_bucket(_, Bucket,_) -> << <<"/">>/binary, Bucket/binary >>.


%% @doc Retrieve URI
%% @private
%%
%% AWS-S3 spec have two kind of path styles(bucket in a subdomain or in a URI).
%% We MUST get rid of a bucket part when the bucket is included in a URI.
%% There are 5 patterns to be handled by this function
%% Details are below.
%% +-----------------+------------------------+-------------------+
%% | Bucket          | URI                    | Expected          |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket">>          | <<"">>            |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket/">>         | <<"/">>           |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucketa">>         | <<"/bucketa">>    |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket/path">>     | <<"/path">>       |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket.ext">>      | <<"/bucket.ext">> |
%% +-----------------+------------------------+-------------------+
auth_uri(<<>>, URI) ->
    URI;
auth_uri(Bucket, URI) ->
    case binary:match(URI, Bucket) of
        {1, _} ->
            BucketLen = byte_size(Bucket),
            BucketThresholdLen1 = BucketLen + 1,
            BucketThresholdLen2 = BucketLen + 2,
            URILen = byte_size(URI),
            case URILen of
                BucketThresholdLen1 ->
                    %% /${Bucket} pattern are should be removed
                    remove_dup_bucket(Bucket, URI);
                BucketThresholdLen2 ->
                    <<"/", Bucket:BucketLen/binary, LastChar:8>> = URI,
                    case LastChar == $/ of
                        true ->
                            %% /${Bucket}/ pattern are should be removed
                            remove_dup_bucket(Bucket, URI);
                        false ->
                            %% ex. /${Bucket}.
                            URI
                    end;
                _ ->
                    SegmentLen = length(binary:split(URI, <<"/">>, [global])),
                    case SegmentLen >= 3 of
                        true ->
                            %% ex. /${Bucket}/path_to_file
                            remove_dup_bucket(Bucket, URI);
                        false ->
                            %% /${Bucket}[^/]+ pattern are should not be removed
                            URI
                    end
            end;
        _ -> URI
    end.

%% @doc remove duplicated bucket's name from path
%% @private
remove_dup_bucket(Bucket, URI) ->
    SkipSize = size(Bucket) + 1,
    binary:part(URI, {SkipSize, size(URI) - SkipSize}).

%% @doc Retrieve resources
%% @private
auth_resources(CannonocalizedResources) ->
    case lists:foldl(fun({K0, V0}, Acc0) ->
                             K1 = string:to_lower(K0),
                             case lists:keysearch(K1, 1, Acc0) of
                                 {value, {_, V1}} ->
                                     ordsets:add_element({K1, V1 ++ "," ++ V0},
                                                         lists:keydelete(K1, 1, Acc0));
                                 false ->
                                     ordsets:add_element({K1, V0}, Acc0)
                             end
                     end, [], CannonocalizedResources) of
        [] ->
            <<>>;
        Headers ->
            lists:foldl(fun({K2, V2}, Acc1) ->
                                BinKey =  list_to_binary(K2),
                                BinVal =  list_to_binary(V2),
                                <<Acc1/binary, BinKey/binary, ":", BinVal/binary, "\n" >>
                        end, <<>>, Headers)
    end.


%% @doc Retrieve sub-resources
%% @private
%% QueryStr must be sorted lexicographically by param name at caller
auth_sub_resources(QueryStr) ->
    ParamList = binary:split(QueryStr, [<<"?">>, <<"&">>], [global]),
    lists:foldl(fun(<<>>, Acc) ->
                       %% ignore empty elements 
                       Acc;
                   (Param, <<>>) ->
                       %% append '?' to first param
                       [Key|Rest] = binary:split(Param, <<"=">>),
                       case binary:match(Key, ?SUB_RESOURCES) of
                           nomatch -> <<>>;
                           _ ->
                               case Rest of
                                   [] -> <<"?", Key/binary>>;
                                   [Val|_] ->
                                       DecodedVal = cowboy_http:urldecode(Val),
                                       <<"?", Key/binary, "=", DecodedVal/binary>>
                               end
                       end;
                   (Param, Acc) ->
                       %% append '&' to other params
                       [Key|Rest] = binary:split(Param, <<"=">>),
                       case binary:match(Key, ?SUB_RESOURCES) of
                           nomatch -> Acc;
                           _ ->
                               case Rest of
                                   [] -> <<Acc/binary, "&", Key/binary>>;
                                   [Val|_] ->
                                       DecodedVal = cowboy_http:urldecode(Val),
                                       <<Acc/binary, "&", Key/binary, "=", DecodedVal/binary>>
                               end
                       end
                end, <<>>, ParamList).

-ifdef(TEST).

auth_uri_test() ->
    <<"">> = auth_uri(<<"bbb">>, <<"/bbb">>),
    <<"/">> = auth_uri(<<"bbb">>, <<"/bbb/">>),
    <<"/bbb.txt">> = auth_uri(<<"bbb">>, <<"/bbb/bbb.txt">>),
    <<"/bbb.txt">> = auth_uri(<<"bbb">>, <<"/bbb.txt">>).

-endif.
