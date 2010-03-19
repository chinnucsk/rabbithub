-module(rabbithub_pseudo_queue).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("rabbithub.hrl").

-record(state, {subscription, secret, queue_name}).

init([Lease = #rabbithub_lease{subscription = Subscription, secret = Secret}]) ->
    process_flag(trap_exit, true),
    case rabbithub_subscription:register_subscription_pid(Lease, self(), ?MODULE) of
        ok ->
            really_init(Subscription, Secret);
        expired ->
            {stop, normal};
        duplicate ->
            {stop, normal}
    end.

really_init(Subscription = #rabbithub_subscription{resource = Resource,
                                                   topic = Topic},
           Secret) ->
    QueueName = rabbithub:r(queue, rabbit_guid:binstring_guid("amq.http.pseudoqueue")),
    Q = rabbit_amqqueue:pseudo_queue(QueueName, self()),
    Q = rabbit_amqqueue:internal_declare(Q, false),
    case rabbit_exchange:add_binding(Resource, QueueName, list_to_binary(Topic), []) of
        ok ->
            {ok, #state{subscription = Subscription,
                        secret = Secret,
                        queue_name = QueueName}};
        {error, exchange_not_found} ->
            {stop, not_found}
    end.

handle_call(Request, _From, State) ->
    {stop, {unhandled_call, Request}, State}.

handle_cast({deliver, _Txn = none, BasicMessage, _ChPid},
            State = #state{secret = Secret, subscription = Subscription}) ->
    case rabbithub:deliver_via_post(Subscription, Secret, BasicMessage, []) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ok = rabbithub:error_and_unsub(Subscription,
                                           {rabbithub_pseudo_queue, http_post_failure, Reason})
    end,
    {noreply, State};
handle_cast(shutdown, State) ->
    {stop, normal, State};
handle_cast(Request, State) ->
    {stop, {unhandled_cast, Request}, State}.

handle_info(Request, State) ->
    {stop, {unhandled_info, Request}, State}.

terminate(_Reason, _State = #state{subscription = Subscription,
                                   queue_name = QueueName}) ->
    error_logger:info_report({stopping_pseudo_queue, _Reason, _State}),
    ok = rabbithub_subscription:erase_subscription_pid(Subscription),
    rabbit_amqqueue:internal_delete(QueueName),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
