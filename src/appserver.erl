%%%-------------------------------------------------------------------
%%% File    : appserver.erl
%%% Author  : Magnus Ahltorp <ahltorp@nada.kth.se>
%%% Descrip.: SIP application server. Handles forking and other more
%%%           advanced message routing for our users.
%%%
%%% Created : 09 Dec 2002 by Magnus Ahltorp <ahltorp@nada.kth.se>
%%%-------------------------------------------------------------------
-module(appserver).

%%--------------------------------------------------------------------
%%% Standard YXA SIP-application callback functions
%%--------------------------------------------------------------------
-export([
	 init/0,
	 request/3,
	 response/3,

	 test/0
	]).

%% exported for CPL subsystem
-export([locations_to_actions/2,
	 location_to_call_action/2
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("sipproxy.hrl").
-include("siprecords.hrl").
-include("sipsocket.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
-define(APPSERVER_GLUE_TIMEOUT, 1200 * 1000).
-define(SIPPIPE_TIMEOUT, 900).


%%====================================================================
%% Behaviour functions
%% Standard YXA SIP-application callback functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init()
%% Descrip.: YXA applications must export an init/0 function.
%% Returns : [Tables, Mode, SupData]
%%           Tables  = list() of atom(), remote mnesia tables the YXA
%%                     startup sequence should make sure are available
%%           Mode    = stateful
%%           SupData = {append, SupSpec} |
%%                     none
%%           SupSpec = OTP supervisor child specification. Extra
%%                     processes this application want the
%%                     sipserver_sup to start and maintain.
%%--------------------------------------------------------------------
init() ->
    [[user, numbers, phone, cpl_script_graph, gruu], stateful, none].



%%--------------------------------------------------------------------
%% Function: request(Request, Origin, LogStr)
%%           Request = request record()
%%           Origin  = siporigin record()
%%           LogStr  = string()
%% Descrip.: YXA applications must export an request/3 function.
%% Returns : Yet to be specified. Return 'ok' for now.
%%--------------------------------------------------------------------

%%
%% REGISTER
%%
request(#request{method = "REGISTER"} = Request, Origin, LogStr) when is_record(Origin, siporigin) ->
    logger:log(normal, "Appserver: ~s Method not applicable here -> 403 Forbidden", [LogStr]),
    transactionlayer:send_response_request(Request, 403, "Forbidden"),
    ok;

%%
%% ACK
%%
request(#request{method = "ACK"} = Request, Origin, LogStr) when is_record(Origin, siporigin) ->
    case local:get_user_with_contact(Request#request.uri) of
	none ->
	    logger:log(normal, "Appserver: ~s -> Forwarding ACK statelessly (to unknown SIP user)",
		       [LogStr]),
	    transportlayer:stateless_proxy_ack("appserver", Request, LogStr);
	SIPuser ->
	    logger:log(normal, "Appserver: ~s -> Forwarding ACK statelessly (to SIP user ~p)",
		       [LogStr, SIPuser]),
	    transportlayer:stateless_proxy_ack("appserver", Request, LogStr)
    end,
    ok;

%%
%% CANCEL
%%
request(#request{method = "CANCEL"} = Request, Origin, LogStr) when is_record(Origin, siporigin) ->
    logger:log(debug, "Appserver: ~s -> CANCEL not matching any existing transaction received, "
	       "answer 481 Call/Transaction Does Not Exist", [LogStr]),
    transactionlayer:send_response_request(Request, 481, "Call/Transaction Does Not Exist");

%%
%% Anything but REGISTER, ACK and CANCEL
request(Request, Origin, LogStr) when is_record(Request, request), is_record(Origin, siporigin) ->
    case local:is_request_to_this_proxy(Request) of
	true ->
	    request_to_me(Request, LogStr);
	false ->
	    %% Ok, request was not for this proxy itself - now just make sure we are supposed to fork it.
	    {ShouldFork, NoForkReason, PipeDst} =
		case keylist:fetch('route', Request#request.header) of
		    [] ->
			URI = Request#request.uri,
			case url_param:find(URI#sipurl.param_pairs, "maddr") of
			    [] ->
				{true, "", none};
			    _ ->
				%% RFC3261 #16.5 (Determining Request Targets) says a proxy MUST
				%% use ONLY the maddr in the Request-URI as target, if set.
				ApproxMsgSize = siprequest:get_approximate_msgsize(Request),
				D = sipdst:url_to_dstlist(URI, ApproxMsgSize, URI),
				D2 = lists:map(fun(H) ->
						       sipdst:dst2str(H)
					       end, D),
				logger:log(debug, "Appserver: Turned Request-URI with maddr set (~s) "
					   "into dst-list : ~p", [sipurl:print(URI), D2]),
				{false, "maddr Request-URI parameter present", D}
			end;
		    _ ->
			%% Request has a Route header, this proxy probably added a Record-Route in a previous
			%% fork, and this request should just be proxyed - not forked.
			{false, "Route-header present", route}
		end,
	    case ShouldFork of
		true ->
		    create_session(Request, Origin, LogStr, true);
		false ->
		    %% XXX check credentials here - our appserver is currently an open relay!
		    logger:log(normal, "Appserver: ~s -> Not forking, just forwarding (~s)", [LogStr, NoForkReason]),
		    THandler = transactionlayer:get_handler_for_request(Request),
		    sippipe:start(THandler, none, Request, PipeDst, ?SIPPIPE_TIMEOUT)
	    end
    end,
    ok.


%%--------------------------------------------------------------------
%% Function: response(Response, Origin, LogStr)
%%           Response = response record()
%%           Origin   = siporigin record()
%%           LogStr   = string()
%% Descrip.: YXA applications must export an response/3 function.
%% Returns : Yet to be specified. Return 'ok' for now.
%%--------------------------------------------------------------------
response(Response, Origin, LogStr) when is_record(Response, response), is_record(Origin, siporigin) ->
    %% RFC 3261 16.7 says we MUST act like a stateless proxy when no
    %% transaction can be found
    #response{status = Status, reason = Reason} = Response,
    logger:log(normal, "incomingproxy: Response to ~s: '~p ~s', no matching transaction - proxying statelessly",
	       [LogStr, Status, Reason]),
    transportlayer:send_proxy_response(none, Response),
    ok.


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------


%%--------------------------------------------------------------------
%% Function: request_to_me(Request, LogTag)
%%           Request = request record()
%%           LogTag  = string()
%% Descrip.: Request is meant for this proxy, if it is OPTIONS we
%%           respond 200 Ok, otherwise we respond 481 Call/
%%           transaction does not exist.
%% Returns : Does not matter.
%%--------------------------------------------------------------------
request_to_me(#request{method = "OPTIONS"} = Request, LogTag) ->
    logger:log(normal, "~s: appserver: OPTIONS to me -> 200 OK", [LogTag]),
    logger:log(debug, "XXX The OPTIONS response SHOULD include Accept, Accept-Encoding,"
	       " Accept-Language, and Supported headers. RFC 3261 section 11"),
    transactionlayer:send_response_request(Request, 200, "OK");

request_to_me(Request, LogTag) when is_record(Request, request) ->
    logger:log(normal, "~s: appserver: non-OPTIONS request to me -> 481 Call/Transaction Does Not Exist",
	       [LogTag]),
    transactionlayer:send_response_request(Request, 481, "Call/Transaction Does Not Exist").


%%--------------------------------------------------------------------
%% Function: create_session(Request, Origin, LogStr, DoCPL)
%%           Request = request record()
%%           Origin  = siporigin record()
%%           LogStr  = string()
%%           DoCPL   = true | false, do CPL or not
%% Descrip.: Request was not meant for this proxy itself - find out if
%%           this request is for one of our users, and if so find out
%%           what actions to perform for the request.
%% Returns : void() | throw({siperror, ...})
%%--------------------------------------------------------------------
create_session(Request, Origin, LogStr, DoCPL) when is_record(Request, request), is_record(Origin, siporigin) ->
    case get_actions(Request#request.uri, DoCPL) of
	nomatch ->
	    create_session_nomatch(Request, LogStr);
	{cpl, User, Graph} ->
	    create_session_cpl(Request, Origin, LogStr, User, Graph);
	{ok, Users, Actions, Surplus} ->
	    create_session_actions(Request, Users, Actions, Surplus)
    end.

%%--------------------------------------------------------------------
%% Function: create_session_actions(Request, Users, Actions)
%%           Request = request record()
%%           Users   = list() of string(), list of SIP usernames
%%           Actions = list() of sipproxy_action record()
%% Descrip.: The request was turned into a set of Actions (derived
%%           from it's URI matching a set of Users).
%% Returns : void() | throw({siperror, ...})
%% Note    : When we start the appserver_glue process, we should
%%           ideally not do a spawn but instead just execute it.
%%           Currently this is the way we do it though (to keep the
%%           code clean). Since this process is the parent of the
%%           server transaction, we must stay alive until the
%%           process that does the actual work exits - so we monitor
%%           it.
%%--------------------------------------------------------------------
create_session_actions(Request, Users, Actions, Surplus) when is_record(Request, request), is_list(Users),
							      is_list(Actions), is_list(Surplus) ->
    logger:log(debug, "Appserver: User(s) ~p actions :~n~p", [Users, Actions]),
    {ok, Pid} = appserver_glue:start_link(Request, Actions, Surplus),
    MonitorRef = erlang:monitor(process, Pid),
    receive
	{'DOWN', MonitorRef, process, Pid, _Info} ->
	    ok;
	Msg ->
	    %% We don't exit/crash on this since it might be a late reply from a gen_sever:call() that
	    %% timed out. Since we have apparently chosen to ignore the timeout earlier, we don't
	    %% consider this an error.
	    logger:log(error, "Appserver: Received unknown signal after starting appserver_glue worker : ~p",
		       [Msg]),
	    create_session_actions(Request, Users, Actions, Surplus)
    after ?APPSERVER_GLUE_TIMEOUT ->
	    %% We should _really_ never get here, but just as an additional safeguard...
	    logger:log(error, "appserver: ERROR: the appserver_glue process I started (~p) never finished! Exiting.",
		       [Pid]),
	    erlang:error(appserver_glue_never_finished)
    end.

%%--------------------------------------------------------------------
%% Function: create_session_nomatch(Request, Logstr)
%%           Request = request record()
%%           LogStr  = string(), describes the request
%% Descrip.: No actions found for this request. Check if we should
%%           forward it anyways, or respond '404 Not Found'.
%% Returns : void() | throw({siperror, ...})
%%--------------------------------------------------------------------
create_session_nomatch(Request, LogStr) when is_record(Request, request), is_list(LogStr) ->
    %% Check if the Request-URI is the registered location of one of our users. If we added
    %% a Record-Route to an earlier request, this might be an in-dialog request destined
    %% for one of our users. Such in-dialog requests will have the users Contact (registered
    %% location hopefully) as Request-URI.
    case local:get_user_with_contact(Request#request.uri) of
	none ->
	    logger:log(normal, "Appserver: ~s -> 404 Not Found (no actions, unknown user)",
		       [LogStr]),
	    transactionlayer:send_response_request(Request, 404, "Not Found");
	SIPuser when is_list(SIPuser) ->
	    logger:log(normal, "Appserver: ~s -> Not forking, just forwarding (no actions found, SIP user ~p)",
		       [LogStr, SIPuser]),
	    ApproxMsgSize = siprequest:get_approximate_msgsize(Request),
	    DstList = sipdst:url_to_dstlist(Request#request.uri, ApproxMsgSize, Request#request.uri),
	    THandler = transactionlayer:get_handler_for_request(Request),
	    sippipe:start(THandler, none, Request, DstList, ?SIPPIPE_TIMEOUT)
    end.

%%--------------------------------------------------------------------
%% Function: create_session_cpl(Request, Origin, LogStr, User, Graph)
%%           Request = request record()
%%           Origin  = siporigin record()
%%           LogStr  = string()
%%           User    = string(), SIP username of CPL script owner
%%           Graph   = term(), CPL graph
%% Descrip.: We found a CPL script that should be applied to this
%%           request (or perhaps have this request applied to it). Do
%%           that and handle any return values. Noteably handle a CPL
%%           return value of '{server_default_action}' by calling
%%           create_session(...) again, but this time with DoCPL set
%%           to 'false' to not end up here again.
%% Returns : void() | throw({siperror, ...})
%%--------------------------------------------------------------------
create_session_cpl(Request, Origin, LogStr, User, Graph)
  when is_record(Request, request), is_record(Origin, siporigin), is_list(LogStr), is_list(User) ->
    Res = interpret_cpl:process_cpl_script(Request, User, Graph, incoming),
    case Res of
	{server_default_action} ->
	    %% Loop back to create_session, but tell it to not do CPL again
	    create_session(Request, Origin, LogStr, false);
	ok ->
	    ok;
	Unknown ->
	    logger:log(error, "appserver: Unknown return value from process_cpl_script(...) user ~p : ~p",
		       [User, Unknown]),
	    throw({siperror, 500, "Server Internal Error"})
    end.

%%--------------------------------------------------------------------
%% Function: get_actions(URI, DoCPL)
%%           URI   = sipuri record()
%%           DoCPL = true | false, do CPL or not
%% Descrip.: Find the SIP user(s) for a URI and make a list() of
%%           sipproxy_action to take for a request destined for that
%%           user(s).
%% Returns : {UserList, ActionsList} |
%%           {cpl, User, Graph}      |
%%           nomatch                 |
%%           throw()
%%           UserList    = list() of SIP usernames (strings)
%%           ActionsList = list() of sipproxy_action record()
%%--------------------------------------------------------------------
get_actions(URI, DoCPL) when is_record(URI, sipurl) ->
    LookupURL = sipurl:set([{pass, none}, {port, none}, {param, []}], URI),
    case local:get_users_for_url(LookupURL) of
	nomatch ->
	    nomatch;
	Users when is_list(Users) ->
	    logger:log(debug, "Appserver: Found user(s) ~p for URI ~s", [Users, sipurl:print(LookupURL)]),
	    get_actions_users(Users, URI#sipurl.proto, DoCPL)
    end.

%% part of get_actions() - single user, look for a CPL script
get_actions_users([User], Proto, true) when is_list(User), is_list(Proto) ->
    case local:get_cpl_for_user(User) of
	{ok, Graph} ->
	    {cpl, User, Graph};
	nomatch ->
	    get_actions_users2([User], Proto)
    end;
%% part of get_actions() - more than one user, or DoCPL == false
get_actions_users(Users, Proto, _DoCPL) when is_list(Users), is_list(Proto) ->
    get_actions_users2(Users, Proto).

%% part of get_actions(), more than one user or DoCPL was false
get_actions_users2(Users, Proto) when is_list(Users), is_list(Proto) ->
    case fetch_actions_for_users(Users, Proto) of
	{ok, [], _Surplus} -> nomatch;
	{ok, Actions, Surplus} when is_list(Actions) ->
	    {ok, Timeout} = yxa_config:get_env(appserver_call_timeout),
	    WaitAction = #sipproxy_action{action  = wait,
					  timeout = Timeout
					 },
	    NewActions = Actions ++ [WaitAction],
	    {ok, Users, NewActions, Surplus}
    end.

%%--------------------------------------------------------------------
%% Function: fetch_actions_for_users(Users, Proto)
%%           Users = list() of string(), list of SIP usernames
%%           Proto = string(), OrigURI proto ("sips" | "sip" | ...)
%% Descrip.: Construct a list of sipproxy_action record()s for a list
%%           of users, based on the contents of the location database
%%           and the KTH-only 'forwards' database. Just ignore the
%%           'forwards' part.
%% Returns : {ok, Actions, Surplus}
%%           Actions = list() of sipproxy_action record()
%%           Surplus = list() of sipproxy_action record(), extra
%%                     contacts for instances with more than one
%%                     location binding (draft-Outbound)
%%--------------------------------------------------------------------
fetch_actions_for_users(Users, Proto) ->
    {ok, Actions, Surplus} = fetch_users_locations_as_actions(Users, Proto),
    NewActions =
	case local:get_forwards_for_users(Users) of
	    nomatch ->
		Actions;
	    [] ->
		Actions;
	    Forwards when is_list(Forwards) ->
		%% Append forwards found to Actions
		forward_call_actions(Forwards, Actions, Proto)
	end,
    {ok, NewActions, Surplus}.

%% part of fetch_actions_for_users/1
fetch_users_locations_as_actions(Users, Proto) ->
    URL = sipurl:new([{proto, Proto}]),
    Locations = local:lookupuser_locations(Users, URL),
    locations_to_actions(Locations).

%%--------------------------------------------------------------------
%% Function: locations_to_actions(Locations)
%%           locations_to_actions(Locations, Timeout)
%%           Locations = list() of Loc
%%                 Loc = siplocationdb_e record() |
%%                       {URL, Timeout}           |
%%                       {wait, Timeout}
%%                 URL = sipurl record()
%%             Timeout = integer()
%% Descrip.: Turn a list of location database entrys/pseudo-actions
%%           into a list of sipproxy_action record()s.
%% Returns : {ok, Actions, Surplus}
%%           Actions = list() of sipproxy_action record()
%%           Surplus = list() of sipproxy_action record(), extra
%%                     contacts for instances with more than one
%%                     location binding (draft-Outbound)
%%--------------------------------------------------------------------
locations_to_actions(L) when is_list(L) ->
    {ok, CallTimeout} = yxa_config:get_env(appserver_call_timeout),
    locations_to_actions2(L, CallTimeout, [], []).

locations_to_actions(L, Timeout) when is_list(L), is_integer(Timeout) ->
    %% Exported for CPL subsystem
    locations_to_actions2(L, Timeout, [], []).

locations_to_actions2([], _CallTimeout, Res, Surplus) ->
    {ok, lists:reverse(Res), Surplus};

locations_to_actions2([H | T] = In, CallTimeout, Res, Surplus) when is_record(H, siplocationdb_e) ->
    case H#siplocationdb_e.instance of
	[] ->
	    CallAction = location_to_call_action(H, CallTimeout),
	    locations_to_actions2(T, CallTimeout, [CallAction | Res], Surplus);
	Instance when is_list(Instance) ->
	    %% draft-Outbound says we "MUST NOT populate the target set with more than one
	    %% contact with the same AOR and instance-id at a time.". AOR translates to SipUser
	    %% in YXA.
	    [First | Rest] = Group = get_locations_with_instance(Instance, H#siplocationdb_e.sipuser, In),
	    CallAction = location_to_call_action(First, CallTimeout),
	    MoreSurplus = [location_to_call_action(E, CallTimeout) || E <- Rest],
	    %% Remove all entrys we separated into the surplus list from the ones we are going
	    %% to process next.
	    NewTail = T -- Group,
	    %% put action made out of First in Res, all locations matching Firsts user and instance
	    %% into our Surplus list and recurse upon the NewTail we created
	    locations_to_actions2(NewTail, CallTimeout, [CallAction | Res], Surplus ++ MoreSurplus)
    end;

locations_to_actions2([{URL, Timeout} | T], CallTimeout, Res, Surplus) when is_record(URL, sipurl),
									    is_integer(Timeout) ->
    CallAction = #sipproxy_action{action  = call,
				  requri  = URL,
				  timeout = Timeout
				 },
    locations_to_actions2(T, CallTimeout, [CallAction | Res], Surplus);

locations_to_actions2([{wait, Timeout} | T], CallTimeout, Res, Surplus) ->
    WaitAction = #sipproxy_action{action  = wait,
				  timeout = Timeout
				 },
    locations_to_actions2(T, CallTimeout, [WaitAction | Res], Surplus).

location_to_call_action(H, Timeout) ->
    URL = siplocation:to_url(H),
    %% RFC3327
    Path =
	case lists:keysearch(path, 1, H#siplocationdb_e.flags) of
	    {value, {path, Path1}} ->
		Path1;
	    false ->
		[]
	end,
    #sipproxy_action{action	= call,
		     requri	= URL,
		     path	= Path,
		     timeout	= Timeout,
		     user	= H#siplocationdb_e.sipuser,
		     instance	= H#siplocationdb_e.instance
		    }.

get_locations_with_instance(Instance, SipUser, In) ->
    %% filter out all entrys from In which have instance and user matching our parameters
    L = [E || E <- In, E#siplocationdb_e.instance == Instance, E#siplocationdb_e.sipuser == SipUser],
    siplocation:sort_most_recent_first(L).


%%--------------------------------------------------------------------
%% Function: forward_call_actions(ForwardList, Actions)
%%           ForwardList = list() of sipproxy_forward record()
%%           DoCPL = true | false, do CPL or not
%% Descrip.: This is something Magnus at KTH developed to suit their
%%           needs of forwarding calls. He hasn't to this date
%%           committed all of the implementation - so don't use it.
%%           Use CPL to accomplish forwards instead.
%% Returns : NewActions = list() of sipproxy_action record()
%%--------------------------------------------------------------------
%% forward_call_actions/2 helps fetch_actions_for_users/1 make a list of
%% sipproxy_action out of a list of forwards, a timeout value and
%% "concurrent ringing or not" information
forward_call_actions([Fwd], Actions, Proto) when is_record(Fwd, sipproxy_forward), is_list(Actions),
						 is_list(Proto) ->
    #sipproxy_forward{user	= User,
		      forwards	= Forwards,
		      timeout	= Timeout,
		      localring	= Localring
		     } = Fwd,
    ForwardActions = forward_call_actions_create_calls(Forwards, Localring, User, Proto),
    case {Localring, Timeout} of
	{_, 0} ->
	    %% No timeout in between original actions and ForwardActions
	    lists:append(Actions, ForwardActions);
	{true, _} ->
	    WaitAction = #sipproxy_action{action  = wait,
					  timeout = Timeout},
	    lists:append(Actions, [WaitAction | ForwardActions]);
	{false, _} ->
	    WaitAction = #sipproxy_action{action  = wait,
					  timeout = Timeout},
	    lists:append(Actions, [WaitAction | ForwardActions])
    end.

%% part of forward_call_actions/3 - turn a list of forward URIs into a list of sipproxy_action call records
forward_call_actions_create_calls(Forwards, Localring, User, Proto) when is_list(Forwards),
									 Localring == true ; Localring == false,
									 is_list(Proto), is_list(User) ->
    {ok, FwdTimeout} = yxa_config:get_env(appserver_forward_timeout),
    forward_call_actions_create_calls2(Forwards, FwdTimeout, Localring, User, Proto, []).

forward_call_actions_create_calls2([H | T], Timeout, Localring, User, Proto, Res) when is_record(H, sipurl) ->
    %% Preserve SIPS protocol if original request was SIPS
    FwdURI = case {Proto, H#sipurl.proto} of
		 {"sips", "sip"} ->
		     %% Turn SIP URI into SIPS
		     H#sipurl{proto="sips"};
		 {"sips", _NonSip} ->
		     %% ignore this forward since original request was SIPS and
		     %% this forwards URI is not upgradeable to a SIPS URI
		     logger:log(debug, "Appserver: Ignoring forward ~p since original request was a "
				"SIPS request and I can't upgrade protocol ~p to SIPS",
				[sipurl:print(H), H#sipurl.proto]),
		     ignore;
		 {_Proto1, _Proto2} ->
		     H
	     end,
    case FwdURI of
	ignore ->
	    forward_call_actions_create_calls2(T, Timeout, Localring, User, Proto, Res);
	_ ->
	    This = #sipproxy_action{action  = call,
				    requri  = FwdURI,
				    timeout = Timeout,
				    user    = User},
	    forward_call_actions_create_calls2(T, Timeout, Localring, User, Proto, [This | Res])
    end;
forward_call_actions_create_calls2([], _Timeout, _Localring, _User, _Proto, Res) ->
    lists:reverse(Res).




%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: test()
%% Descrip.: autotest callback
%% Returns : ok
%%--------------------------------------------------------------------
test() ->

    %% locations_to_actions2(L, CallTimeout, [], [])
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "locations_to_actions2/4 - 1"),
    %% test simple case
    LToActions_Locations1 = [#siplocationdb_e{address	= sipurl:parse("sip:ft@1.example.org"),
					      sipuser	= "user1",
					      flags	= [],
					      instance	= []
					     },
			     #siplocationdb_e{address	= sipurl:parse("sip:ft@2.example.org"),
					      sipuser	= "user2",
					      flags	= [],
					      instance	= []
					     }
			    ],
    LToActions_Actions1 = [#sipproxy_action{action	= call,
					    timeout	= 10,
					    requri	= sipurl:parse("sip:ft@1.example.org"),
					    path	= [],
					    user	= "user1",
					    instance	= []
					   },
			   #sipproxy_action{action	= call,
					    timeout	= 10,
					    requri	= sipurl:parse("sip:ft@2.example.org"),
					    path	= [],
					    user	= "user2",
					    instance	= []
					   }
			  ],

    {ok, LToActions_Actions1, []} = locations_to_actions2(LToActions_Locations1, 10, [], []),

    autotest:mark(?LINE, "locations_to_actions2/4 - 2"),
    %% test complex case with same instances and usernames
    LToActions_Locations2 = [#siplocationdb_e{address	= sipurl:parse("sip:ft@1.example.org"),
					      sipuser	= "user",
					      flags	= [{registration_time, 100}],
					      instance	= "<urn:test:match>"
					     },
			     #siplocationdb_e{address	= sipurl:parse("sip:ft@2.example.org"),
					      sipuser	= "user",
					      flags	= [{registration_time, 200},
							   {path, ["<test;lr>"]}
							  ],
					      instance	= "<urn:test:match>"
					     }
			    ],
    LToActions_Actions2 = [#sipproxy_action{action	= call,
					    timeout	= 10,
					    requri	= sipurl:parse("sip:ft@2.example.org"),
					    path	= ["<test;lr>"],
					    user	= "user",
					    instance	= "<urn:test:match>"
					   }
			  ],
    LToActions_Surplus2 = [#sipproxy_action{action	= call,
					    timeout	= 10,
					    requri	= sipurl:parse("sip:ft@1.example.org"),
					    path	= [],
					    user	= "user",
					    instance	= "<urn:test:match>"
					   }
			  ],
    {ok, LToActions_Actions2, LToActions_Surplus2} = locations_to_actions2(LToActions_Locations2, 10, [], []),

    autotest:mark(?LINE, "locations_to_actions2/4 - 3"),
    %% test with non-siplocationdb_e input
    LToActions_Locations3 = [#siplocationdb_e{address	= sipurl:parse("sip:ft@3.example.org"),
					      sipuser	= "user3",
					      flags	= [],
					      instance	= []
					     },
			     {wait, 29},
			     {sipurl:parse("sip:foo@4.example.org"), 31}
			    ],
    LToActions_Actions3 = [#sipproxy_action{action	= call,
					    timeout	= 30,
					    requri	= sipurl:parse("sip:ft@3.example.org"),
					    path	= [],
					    user	= "user3",
					    instance	= []
					   },
			   #sipproxy_action{action	= wait,
					    timeout	= 29
					   },
			   #sipproxy_action{action	= call,
					    timeout	= 31,
					    requri	= sipurl:parse("sip:foo@4.example.org")
					   }
			  ],

    {ok, LToActions_Actions3, []} = locations_to_actions2(LToActions_Locations3, 30, [], []),

    ok.
