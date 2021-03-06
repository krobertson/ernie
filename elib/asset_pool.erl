-module(asset_pool).
-behaviour(gen_server).

%% api
-export([start_link/1, start/1, lease/0, return/1, reload_assets/0, idle_worker_count/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {assets = undefined,
                handler = undefined,
                token = undefined}).

%%====================================================================
%% API
%%====================================================================

start_link(Args) ->
  gen_server:start_link({global, ?MODULE}, ?MODULE, Args, []).

start(Args) ->
  gen_server:start({global, ?MODULE}, ?MODULE, Args, []).

lease() ->
  gen_server:call({global, ?MODULE}, {lease}).

return(Asset) ->
  gen_server:call({global, ?MODULE}, {return, Asset}).

reload_assets() ->
  gen_server:call({global, ?MODULE}, {reload_assets}).

idle_worker_count() ->
  gen_server:call({global, ?MODULE}, {idle_worker_count}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Count, Handler]) ->
  process_flag(trap_exit, true),
  error_logger:info_msg("~p starting~n", [?MODULE]),
  Token = make_ref(),
  Assets = start_handlers(Count, Handler, Token),
  {ok, #state{assets = Assets, handler = Handler, token = Token}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({lease}, _From, State) ->
  Token = State#state.token,
  case queue:out(State#state.assets) of
    {{value, Asset}, Assets2} ->
      {asset, Port, AssetToken} = Asset,
      case AssetToken =:= Token of
        false ->
          port_wrapper:close(Port),
          Handler = State#state.handler,
          NewAsset = create_asset(Handler, Token);
        true ->
          NewAsset = Asset
      end,
      {reply, {ok, NewAsset}, State#state{assets = Assets2}};
    {empty, _Assets2} ->
      {reply, empty, State}
  end;
handle_call({return, Asset}, _From, State) ->
  Token = State#state.token,
  {asset, Port, AssetToken} = Asset,
  case AssetToken =:= Token of
    false ->
      port_wrapper:close(Port),
      Handler = State#state.handler,
      NewAsset = create_asset(Handler, Token);
    true ->
      NewAsset = Asset
  end,
  Assets2 = queue:in(NewAsset, State#state.assets),
  {reply, ok, State#state{assets = Assets2}};
handle_call({reload_assets}, _From, State) ->
  Token = make_ref(),
  {reply, ok, State#state{token = Token}};
handle_call({idle_worker_count}, _From, State) ->
  WorkerCount = queue:len(State#state.assets),
  {reply, WorkerCount, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', _Pid, normal}, State) ->
  {noreply, State};
handle_info({'EXIT', Pid, Error}, State) ->
  error_logger:error_msg("Port ~p closed with ~p, restarting port...~n", [Pid, Error]),
  ValidAssets = queue:filter(fun(Item) -> {asset, A, _T} = Item, A =/= Pid end, State#state.assets),
  Handler = State#state.handler,
  Token = State#state.token,
  NewAsset = create_asset(Handler, Token),
  Assets = queue:in(NewAsset, ValidAssets),
  {noreply, State#state{assets = Assets}};
handle_info(Msg, State) ->
  error_logger:error_msg("Unexpected message: ~p~n", [Msg]),
  {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

start_handlers(Count, Handler, Token) ->
  start_handlers(queue:new(), Count, Handler, Token).

start_handlers(Assets, 0, _Handler, _Token) ->
  Assets;
start_handlers(Assets, Count, Handler, Token) ->
  Asset = create_asset(Handler, Token),
  Assets2 = queue:in(Asset, Assets),
  start_handlers(Assets2, Count - 1, Handler, Token).

create_asset(Handler, Token) ->
  {asset, port_wrapper:wrap_link(Handler), Token}.