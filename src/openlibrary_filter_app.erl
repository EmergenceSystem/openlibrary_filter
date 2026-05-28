%%%-------------------------------------------------------------------
%%% @doc Open Library book search agent.
%%%
%%% Searches the Open Library API (Internet Archive) for books and
%%% returns embryos with title, author, year, and book URL.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(openlibrary_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(SEARCH_URL,
    "https://openlibrary.org/search.json"
    "?limit=10&fields=key,title,author_name,first_publish_year,isbn&q=").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"openlibrary">>, <<"books">>,
                                      <<"library">>, <<"isbn">>,
                                      <<"literature">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case openlibrary_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(openlibrary_filter_query_listener),
    catch em_pop_sup:stop_node(openlibrary_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(openlibrary_filter, pop_port,   9480),
    QueryPort = application:get_env(openlibrary_filter, query_port, 9481),
    Seeds     = application:get_env(openlibrary_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(openlibrary_filter),
    catch cowboy:stop_listener(openlibrary_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(openlibrary_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => openlibrary_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(openlibrary_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[openlibrary_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Query, Timeout} = extract_params(JsonBinary),
    fetch_results(Query, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Query   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Query, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

fetch_results("", _) -> [];
fetch_results(Query, Timeout) ->
    Url = lists:flatten(io_lib:format("~s~s", [?SEARCH_URL, uri_string:quote(Query)])),
    Headers = [{"User-Agent", "openlibrary_filter/1.0"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_results(Body);
        _ ->
            []
    end.

parse_results(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"docs">> := Docs} when is_list(Docs) ->
            lists:filtermap(fun build_embryo/1, Docs);
        _ ->
            []
    catch
        _:_ -> []
    end.

build_embryo(#{<<"key">> := Key, <<"title">> := Title} = Doc) ->
    Url     = lists:flatten(io_lib:format("https://openlibrary.org~s", [Key])),
    Authors = format_authors(maps:get(<<"author_name">>, Doc, [])),
    Year    = maps:get(<<"first_publish_year">>, Doc, null),
    Resume  = format_resume(Authors, Year),
    {true, #{
        <<"properties">> => #{
            <<"url">>    => list_to_binary(Url),
            <<"resume">> => list_to_binary(Resume),
            <<"title">>  => Title,
            <<"source">> => <<"openlibrary.org">>
        }
    }};
build_embryo(_) ->
    false.

format_authors([]) -> "";
format_authors(Authors) when is_list(Authors) ->
    Strs = [binary_to_list(A) || A <- Authors, is_binary(A)],
    string:join(lists:sublist(Strs, 3), ", ").

format_resume("", null)   -> "";
format_resume(Authors, null) -> Authors;
format_resume("", Year) when is_integer(Year) ->
    integer_to_list(Year);
format_resume(Authors, Year) when is_integer(Year) ->
    Authors ++ " (" ++ integer_to_list(Year) ++ ")".
