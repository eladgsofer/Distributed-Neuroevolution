%%%-------------------------------------------------------------------
%%% @author elad.sofer
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 29. Jul 2021 10:13 PM
%%%-------------------------------------------------------------------
-module(population_fsm).
-author("elad.sofer").

-behaviour(gen_statem).

%% API
-export([start_link/4]).

%% gen_statem callbacks
-export([init/1,fitting_state/3, format_status/2, calc_state/3, terminate/3, callback_mode/0]).
-record(pop_state, {agentsMapper, genes, ets, simSteps, serverId, mutIter,nn_amount, masterPid, agentsIds, nnIds, agentsMgmt}).

-define(SERVER, ?MODULE).


-record(population_fsm_state, {}).
-include("records.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
start_link(NN_Amount, Sim_Steps, MasterPid, EnvParams) ->
  ServerId = utills:generateServerId(?MODULE),
  gen_statem:start_link({local, ServerId}, ?MODULE, {NN_Amount, Sim_Steps, ServerId, MasterPid, EnvParams}, []).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%% @private
%% @doc Whenever a gen_statem is started using gen_statem:start/[3,4] or
%% gen_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
init({NN_Amount, Sim_Steps, ServerId, MasterPid, EnvParams}) ->

  {NNids, AgentsIds} =EnvParams,

  AgentsMapper = createAgentsMapper(AgentsIds),
  CollectorPid = ServerId,
  % Start the agents supervisor
  AgentsMgmt = agents_mgmt:start_link(CollectorPid, NNids, AgentsIds),

  StateData = #pop_state{
    simSteps = Sim_Steps,
    serverId = ServerId,
    masterPid = MasterPid,
    nn_amount=NN_Amount,
    agentsMapper=AgentsMapper,
    agentsMgmt=AgentsMgmt,
    nnIds= NNids,
    agentsIds = AgentsIds},

  % Send the master ACK that I'm ready
  gen_server:cast(MasterPid, {ok, node(), NNids}),
  % call agents mgmt
  io:format("Hi I am FSM ~p~n", [ServerId]),
  {ok, calc_state, StateData}.


%% @private
%% @doc This function is called by a gen_statem when it needs to find out
%% the callback mode of the callback module.
callback_mode() -> state_functions.

%% @private
%% @doc Called (1) whenever sys:get_status/1,2 is called by gen_statem or
%% (2) when gen_statem terminates abnormally.
%% This callback is optional.
format_status(_Opt, [_PDict, _StateName, _State]) -> Status = some_term, Status.

%% @private
%% @doc There should be one instance of this function for each possible
%% state name.  If callback_mode is state_functions, one of these
%% functions is called when gen_statem receives and event from
%% call/2, cast/2, or as a normal process message.
calc_state(cast, {runNetwork, BestGenesIds, MutIter}, #pop_state{agentsIds = AgentsIds, nnIds = NNIds} =  StateData) ->
  io:format("Calc state Recevied: ~p~n", [{runNetwork, BestGenesIds, MutIter}]),

  Genes = db:select_best_genes(BestGenesIds), ALen = length(AgentsIds), GLen = length(Genes),
  NewState = if
               ALen==GLen ->
                 StateData;

               ALen > GLen->
                 SortedAgents = lists:sort(AgentsIds),
                 ActiveAgentsIds = lists:sublist(SortedAgents, GLen),

                 % Delete the agents which aren't needed
                 PassiveAgentsIds = lists:sublist(SortedAgents, GLen + 1, length(SortedAgents)),
                 lists:foreach(fun(C)->supervisor:delete_child(StateData#pop_state.agentsMgmt, C) end, PassiveAgentsIds),

                 %TODO make sure that NNIds, is ordered? potential bug keysort via key 2
                 StateData#pop_state{agentsMapper = createAgentsMapper(ActiveAgentsIds), agentsIds=ActiveAgentsIds, nnIds =lists:sublist(NNIds, 1, GLen)};

               ALen<GLen ->
                 NewAgentsCnt = GLen - ALen,
                 {NewNNIds, NewAgentsIds} = utills:generateNNIds(ALen + 1, NewAgentsCnt), %Tuple of {NNIds, AgentsIds}
                 ActiveAgentsIds = lists:sort(StateData#pop_state.agentsIds ++ NewAgentsIds),

                 % Creating new agents
                 CollectorPid = utills:generateServerId(population_fsm),
                 NewAgentsSpecs = agents_mgmt:generateChildrensSpecs(NewNNIds, NewAgentsIds,CollectorPid), % CollectorPid?
                 lists:foreach(fun(ChildSpec)->supervisor:start_child(StateData#pop_state.agentsMgmt, ChildSpec) end, NewAgentsSpecs),

                 StateData#pop_state{agentsIds=ActiveAgentsIds, agentsMapper = createAgentsMapper(ActiveAgentsIds), nnIds =NNIds ++ NewNNIds}
             end,

  io:format("CALC STATE - EXECUTING AGENTS:~n"),
  broadCastAgents(Genes, NewState#pop_state.agentsIds, MutIter),
  {next_state, fitting_state, NewState#pop_state{mutIter=MutIter}};

% If a sync message arrived before entering the next_state
calc_state(cast, {sync, AgentId}, Data) -> fitting_state(cast, {sync, AgentId}, Data).

fitting_state(cast, {sync, AgentId}, #pop_state{mutIter = MutIter, masterPid = MasterPid, agentsMapper = AgentsMapper, agentsIds = AgentsIds} = Data) ->
  % Update the agents receive checklist
  UpdatedMapper = AgentsMapper#{AgentId=>true},
  % Find if everyone sent their sync
  Pred = fun(_,V) -> V =:= false end,
  SyncMapper = maps:filter(Pred,UpdatedMapper),

  io:format("fitting_staet: got sync from ~p current table is~p~n", [AgentId, SyncMapper]),
  case maps:size(SyncMapper) of
    0 ->
      % prepare an empty mapper
      NextMutationMapper = maps:from_list([{A, false} ||A<-AgentsIds]),
      % sync call to verify server got it, before moving to the next state
      gen_server:cast(MasterPid, {node(), done, MutIter}),
      {next_state,calc_state, Data#pop_state{agentsMapper=NextMutationMapper},[]};

    _->
      {keep_state, Data#pop_state{agentsMapper=UpdatedMapper},[]}
  end.



%% @private
%% @doc This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates with
%% Reason. The return value is ignored.
terminate(_Reason, _StateName, _State = #population_fsm_state{}) -> ok.


%%%===================================================================
%%% Internal functions
%%%===================================================================

broadCastAgents(Genes, AgentsIds, MutIter)->
  AgentsGenesZip = lists:zip(Genes, AgentsIds),
  ExecFunc = fun(ExecData) -> {Gene, Agent} = ExecData,
    gen_server:cast(Agent, {executeIteration, MutIter, Gene}) end,
  % execute all the agents async
  lists:foreach(ExecFunc, AgentsGenesZip).

createAgentsMapper(AgentsIds) ->  maps:from_list([{A, false} ||A<-AgentsIds]).