var G = {}; // the master Global variable

var debug_ignore_auth_failures = false;

G['main_window'] = self;
G['win_list'] = [];
G['appshell_list'] = [];
G['doc_list'] = [];
G['window_name_increment'] = 0;
G['auth_ses'] = '';
G['user_ou'] = '';
G['main_test_variable'] = 'Hello World';
G['org_tree'] = '';
G['my_orgs'] = [];
G['my_orgs_hash'] = {};
G['fieldmap'] = '';
G['patrons'] = {};

G['ap_list'] = []; // actor::profile
G['ap_hash'] = {};
G['cit_list'] = []; // config::identification_type
G['cit_hash'] = {};
G['cst_list'] = []; // config::standing
G['cst_hash'] = {};
G['acpl_list'] = []; // asset::copy_location
G['acpl_hash'] = {}; G['acpl_my_orgs'] = []; G['acpl_my_orgs_hash'] = {};
G['aout_list'] = []; // actor::org_unit_type
G['aout_hash'] = {};
G['ccs_list'] = []; // config::copy_status
G['ccs_hash'] = {};
G['asc_list'] = []; // asset::stat_cat
G['actsc_list'] = []; // actor::stat_cat
G['actsc_hash']; // actor::stat_cat

var mw = G['main_window'];
var auth_meter_incr = 10;

function auth_init() {
	sdump('D_AUTH','TESTING: auth.js: ' + mw.G['main_test_variable'] + '\n');
	sdump('D_AUTH',arg_dump(arguments));
	var np = document.getElementById('name_prompt');
	np.addEventListener("keypress",handle_keypress,false);
	np.focus();
	var pp = document.getElementById('password_prompt');
	pp.addEventListener("keypress",handle_keypress,false);
	self.addEventListener("unload",nice_shutdown,false);
	G['sound'] = xp_sound_init(); 
	//G.sound.beep();
	snd_logon();
}

function handle_keypress(ev) {
	if (ev.keyCode && ev.keyCode == 13) {
		switch(this) {
			case document.getElementById('name_prompt') :
				ev.preventDefault();
				var pp = document.getElementById('password_prompt');
				pp.focus(); pp.select();
			break;
			case document.getElementById('password_prompt') :
				ev.preventDefault();
				var sb = document.getElementById('submit_button');
				sb.focus();
				authenticate();
			break;
			default:
			break;
		}
	}
}

function disable_login_prompts() {
	sdump('D_AUTH',arg_dump(arguments));
	disable_widgets(document,'password_prompt','name_prompt','submit_button');
	G.sound.beep();
}

function enable_login_prompts() {
	sdump('D_AUTH',arg_dump(arguments));
	enable_widgets(document,'password_prompt','name_prompt','submit_button');
	document.getElementById('password_prompt').value = '';
	var np = document.getElementById('name_prompt');
	np.focus(); np.select();
	document.getElementById('auth_meter').value = 0;
	document.getElementById('auth_meter').setAttribute('real', '0.0');
	G.sound.beep();
}

function authenticate() {
	sdump('D_AUTH',arg_dump(arguments));
	timer_init('cat');
	var name = document.getElementById('name_prompt').value;
	if (name.length == 0) { enable_login_prompts(); return; }
	// Talk to the system and authenticate the user.
	user_async_request(
		'open-ils.auth',
		'open-ils.auth.authenticate.init',
		[ name ],
		auth_init_callback
	);
}

function auth_init_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var auth_init;
	try {
		auth_init = request.getResultObject();
		if (!auth_init) { throw('null result'); }
	} catch(E) {
		alert('Login failed on auth_init: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}

	sdump( 'D_AUTH', 'D_AUTH_INIT: ' + typeof(auth_init) + ' : ' + auth_init + '\n');
	var name = document.getElementById('name_prompt').value;
	var pw = document.getElementById('password_prompt').value;

	user_async_request(
		'open-ils.auth',
		'open-ils.auth.authenticate.complete',
		[ name, hex_md5(auth_init + hex_md5(pw)) ],
		auth_ses_callback
	);
	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function auth_ses_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var auth_ses;
	try {
		auth_ses = request.getResultObject();
		if (!auth_ses) { throw('null result'); }
		if (auth_ses == 0) { throw('0 result'); }
	} catch(E) {
		alert('Login failed on auth_ses: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.auth_ses = [ auth_ses ];
	sdump( 'D_AUTH', 'D_AUTH_SES: ' + typeof(mw.G['auth_ses'][0]) + ' : ' + mw.G['auth_ses'][0] + '\n');

	//'open-ils.actor.user.profiles.retrieve',
	user_async_request(
		'open-ils.actor',
		'open-ils.actor.groups.retrieve',
		[],
		ap_list_callback
	);
	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function ap_list_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var ap_list;
	try {
		ap_list = request.getResultObject();
		if (!ap_list) { throw('null result'); }
		if (ap_list.length == 0) { throw('zero length result'); }
	} catch(E) {
		alert('Login failed on ap_list: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.ap_list = ap_list;
	mw.G.ap_hash = convert_object_list_to_hash( ap_list );

	user_async_request(
		'open-ils.actor',
		'open-ils.actor.user.ident_types.retrieve',
		[],
		cit_list_callback
	);
	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function cit_list_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var cit_list;
	try {
		cit_list = request.getResultObject();
		if (!cit_list) { throw('null result'); }
		if (cit_list.length == 0) { throw('zero length result'); }
	} catch(E) {
		alert('Login failed on cit_list: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.cit_list = cit_list;
	mw.G.cit_hash = convert_object_list_to_hash( cit_list );
	
	user_async_request(
		'open-ils.actor',
		'open-ils.actor.standings.retrieve',
		[],
		cst_list_callback
	);

	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function cst_list_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var cst_list;
	try {
		cst_list = request.getResultObject();
		if (!cst_list) { throw('null result'); }
		if (cst_list.length == 0) { throw('zero length result'); }
	} catch(E) {
		alert('Login failed on cst_list: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.cst_list = cst_list;
	mw.G.cst_hash = convert_object_list_to_hash( cst_list );
	sdump('D_AUTH', 'cst_list = ' + js2JSON(cst_list) + '\n');

	user_async_request(
		'open-ils.search',
		'open-ils.search.config.copy_location.retrieve.all',
		[],
		acpl_list_callback
	);
	incr_progressmeter(document,'auth_meter',auth_meter_incr);

}

function acpl_list_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var acpl_list;
	try {
		acpl_list = request.getResultObject();
		if (!acpl_list) { throw('null result'); }
		if (acpl_list.length == 0) { throw('zero length result'); }
	} catch(E) {
		alert('Login failed on acpl_list: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.acpl_list = acpl_list;
	mw.G.acpl_hash = convert_object_list_to_hash( acpl_list );
	sdump('D_AUTH', 'acpl_list = ' + js2JSON(acpl_list) + '\n');

	user_async_request(
		'open-ils.search',
		'open-ils.search.config.copy_status.retrieve.all',
		[],
		ccs_list_callback
	);
	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function ccs_list_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var ccs_list;
	try {
		ccs_list = request.getResultObject();
		if (!ccs_list) { throw('null result'); }
		if (ccs_list.length == 0) { throw('zero length result'); }
	} catch(E) {
		alert('Login failed on ccs_list: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.ccs_list = ccs_list;
	mw.G.ccs_hash = convert_object_list_to_hash( ccs_list );
	sdump('D_AUTH', 'ccs_list = ' + js2JSON(ccs_list) + '\n');

	user_async_request(
		'open-ils.search',
		'open-ils.search.actor.user.session',
		[ mw.G['auth_ses'][0] ],
		user_callback
	);
	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function user_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var user;
	var user_ou;
	try {
		user = request.getResultObject();
		if (!user) { throw('null result'); }
		if (typeof(user) != 'object') { throw('result not an object' + user); }
	} catch(E) {
		alert('Login failed on user: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.user = user;
	mw.G.user_ou = user.home_ou();
	sdump('D_AUTH', "user: " + js2JSON(mw.G['user']) + '\n');
	sdump('D_AUTH', "user_ou: " + js2JSON(mw.G['user_ou']) + '\n');
	/*user_async_request(
		'open-ils.search',
		'open-ils.search.actor.org_tree.retrieve',
		[],
		org_tree_callback
	);*/
	/*user_async_request(
		'open-ils.actor',
		'open-ils.actor.org_types.retrieve',
		[ mw.G.auth_ses[0] ],
		org_type_callback
	);*/
	org_type_callback();
	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function org_type_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var aout_list = globalOrgTypes;
	/*try {
		aout_list = request.getResultObject();
		if (!aout_list) { throw('null result'); }
		if (typeof(aout_list) != 'object') { throw('result not an object' + aout_list); }
		if (aout_list.length == 0) { throw('empty aout_list'); }
	} catch(E) {
		alert('Login failed on aout_list: ' + js2JSON(E)); enable_login_prompts(); return;
	}*/
	mw.G.aout_list = aout_list;
	mw.G.aout_hash = convert_object_list_to_hash( aout_list );
	mw.G.org_tree = globalOrgTree;
	mw.G.org_tree_hash = convert_object_list_to_hash( flatten_ou_branch( globalOrgTree ) );
	mw.G.user_ou = find_ou( mw.G.org_tree, mw.G.user_ou );

	user_async_request(
		'open-ils.actor',
		'open-ils.actor.org_unit.full_path.retrieve',
		[ mw.G.auth_ses[0] ],
		my_orgs_callback
	);
	incr_progressmeter(document,'auth_meter',auth_meter_incr);

}

function my_orgs_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var my_orgs;
	try {
		my_orgs = request.getResultObject();
		if (!my_orgs) { throw('null result'); }
		if (typeof(my_orgs) != 'object') { throw('result not an object' + my_orgs); }
		if (my_orgs.length == 0) { throw('empty my_orgs'); }
	} catch(E) {
		alert('Login failed on my_orgs: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}

	mw.G.my_orgs = my_orgs;
	mw.G.my_orgs_hash = convert_object_list_to_hash( my_orgs );
	sdump('D_AUTH','my_orgs = ' + js2JSON(my_orgs) + '\n');
	mw.G.acpl_my_orgs = filter_list( 
		mw.G.acpl_list, 
		function (obj) {
			if ( typeof obj != 'object' ) return null;
			if ( mw.G.my_orgs_hash[ obj.owning_lib() ] ) return obj;
		}
	);
	mw.G.acpl_my_orgs_hash = convert_object_list_to_hash( mw.G.acpl_my_orgs );
	//sdump('D_AUTH', 'my_orgs.length = ' + mw.G.my_orgs.length + '   other_orgs.length = ' + mw.G.other_orgs.length + '\n');

	user_async_request(
		'open-ils.circ',
		'open-ils.circ.stat_cat.actor.retrieve.all',
		[ mw.G.auth_ses[0], mw.G.user_ou.id() ],
		my_actsc_list_callback
	);

	incr_progressmeter(document,'auth_meter',auth_meter_incr);
}

function my_actsc_list_callback(request) {
	sdump('D_AUTH',arg_dump(arguments));
	var actsc_list;
	try {
		actsc_list = request.getResultObject();
		if (!actsc_list) { throw('null result'); }
		if (actsc_list.length == 0) { throw('zero length result'); }
	} catch(E) {
		alert('Login failed on actsc_list: ' + js2JSON(E)); 
		if (!debug_ignore_auth_failures) {
			enable_login_prompts(); return;
		}
	}
	mw.G.actsc_list = actsc_list;
	mw.G.actsc_hash = convert_object_list_to_hash( actsc_list );
	sdump('D_AUTH', 'actsc_list = ' + js2JSON(actsc_list) + '\n');

	incr_progressmeter(document,'auth_meter',auth_meter_incr);

	spawn_main();

	mw.minimize();

}


function logoff() {
	sdump('D_AUTH',arg_dump(arguments));
	mw.G['auth_ses'] = '';
	close_all_windows();
	enable_login_prompts();
	incr_progressmeter(document,'auth_meter',-100);
	snd_logoff();
}

function nice_shutdown() {
	sdump('D_AUTH',arg_dump(arguments));
	if (ses) { logoff(); ses.disconnect(); }
	snd_exit;
	close_all_windows();
	window.close();
}

