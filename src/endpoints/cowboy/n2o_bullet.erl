-module(n2o_bullet).
-author('Maxim Sokhatsky').
-include_lib("n2o/include/wf.hrl").
-export([init/4]).
-export([stream/3]).
-export([info/3]).
-export([terminate/2]).

-define(PERIOD, 1000).

init(_Transport, Req, _Opts, _Active) ->
    put(actions,[]),
    Ctx = wf_context:init_context(Req),
    NewCtx = wf_core:fold(init,Ctx#context.handlers,Ctx),
    wf_context:context(NewCtx),
    Res = ets:update_counter(globals,onlineusers,{2,1}),
    wf:reg(broadcast,wf:peer(Req)),
    wf:send(broadcast,{counter,Res}),
    Req1 = wf:header(<<"Access-Control-Allow-Origin">>, <<"*">>, NewCtx#context.req),
    {ok, Req1, NewCtx}.

stream(<<"ping">>, Req, State) ->
    wf:info("ping received~n"),
    {reply, <<"pong">>, Req, State};
stream({text,Data}, Req, State) ->
    %wf:info("Text Received ~p",[Data]),
    self() ! Data,
    {ok, Req,State};
stream({binary,Info}, Req, State) ->
    % wf:info("Binary Received: ~p",[Info]),
    Pro = binary_to_term(Info,[safe]),
    Pickled = proplists:get_value(pickle,Pro),
    Linked = proplists:get_value(linked,Pro),
    Depickled = wf:depickle(Pickled),
    % wf:info("Depickled: ~p",[Depickled]),
    case Depickled of
        #ev{module=Module,name=Function,payload=Parameter,trigger=Trigger} ->
            case Function of 
                control_event   -> lists:map(fun({K,V})-> put(K,V) end,Linked),
                                   Module:Function(Trigger, Parameter);
                api_event       -> Module:Function(Parameter,Linked,State);
                event           -> lists:map(fun({K,V})-> put(K,V) end,Linked),
                                   Module:Function(Parameter);
                UserCustomEvent -> Module:Function(Parameter,Trigger,State) end;
          _ -> wf:error("N2O allows only #ev{} events") end,

    Actions = get(actions),
    wf_context:clear_actions(),
    Render = wf:render(Actions),

    GenActions = get(actions),
    RenderGenActions = wf:render(GenActions),
    wf_context:clear_actions(),

    {reply, [Render,RenderGenActions], Req, State};
stream(Data, Req, State) ->
    wf:info("Data Received ~p",[Data]),
    self() ! Data,
    {ok, Req,State}.

render_actions(InitActions) ->
    RenderInit = wf:render(InitActions),
    InitGenActions = get(actions),
    RenderInitGenActions = wf:render(InitGenActions),
    wf_context:clear_actions(),
    [RenderInit,RenderInitGenActions].

info(Pro, Req, State) ->
    Render = case Pro of
        {flush,Actions} ->
            % wf:info("Comet Actions: ~p",[Actions]),
            wf:render(Actions);
        <<"N2O,",Rest/binary>> ->
            Module = State#context.module, Module:event(init),
            InitActions = get(actions),
            wf_context:clear_actions(),
            Pid = wf:depickle(Rest),
            %wf:info("Transition Pid: ~p",[Pid]),
            case Pid of
                undefined -> 
                    %wf:info("Path: ~p",[wf:path(Req)]),
                    %wf:info("Module: ~p",[Module]),
                    Elements = try Module:main() catch C:E -> wf:error_page(C,E) end,
                    wf_core:render(Elements),
                    render_actions(InitActions);

                Transition ->
                    X = Pid ! {'N2O',self()},
                    R = receive Actions -> [ render_actions(InitActions) | wf:render(Actions) ]
                    after 100 ->
                          QS = element(14, Req),
                          wf:redirect(case QS of <<>> -> ""; _ -> "" ++ "?" ++ wf:to_list(QS) end),
                          []
                    end,
                    R
                    end;
        <<"PING">> -> [];
        Unknown ->
            M = State#context.module,
            catch M:event(Unknown),
            Actions = get(actions),
            wf_context:clear_actions(),
            wf:render(Actions) end,
    GenActions = get(actions),
    wf_context:clear_actions(),
    RenderGenActions = wf:render(GenActions),
    wf_context:clear_actions(),
    {reply, [Render,RenderGenActions], Req, State}.

terminate(_Req, _State=#context{module=Module}) ->
    % wf:info("Bullet Terminated~n"),
    Res = ets:update_counter(globals,onlineusers,{2,-1}),
    wf:send(broadcast,{counter,Res}),
    catch Module:event(terminate),
    ok.
