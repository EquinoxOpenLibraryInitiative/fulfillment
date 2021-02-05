dump('entering patron/search_result.js\n');

function $(id) { return document.getElementById(id); }

if (typeof patron == 'undefined') patron = {};
patron.search_result = function (params) {

    JSAN.use('util.error'); this.error = new util.error();
    JSAN.use('util.network'); this.network = new util.network();
    this.w = window;
}

patron.search_result.prototype = {

    'result_cap' : 50,

    'init' : function( params ) {

        var obj = this;

        obj.query = params['query'];
        obj.search_limit = params['search_limit'];
        obj.search_sort = params['search_sort'];

        JSAN.use('OpenILS.data'); this.OpenILS = {}; 
        obj.OpenILS.data = new OpenILS.data(); obj.OpenILS.data.init({'via':'stash'});
        var obscure_dob = String( obj.OpenILS.data.hash.aous['circ.obscure_dob'] ) == 'true';

        var result_cap_setting = obj.OpenILS.data.hash.aous[
            'ui.patron_search.result_cap'
        ];
        if (typeof result_cap_setting != 'undefined') {
            obj.result_cap = Math.abs( result_cap_setting );
        }

        JSAN.use('util.list'); obj.list = new util.list('patron_list');

        JSAN.use('patron.util');
        var columns = obj.list.fm_columns('au',{
            '*' : { 'remove_virtual' : true, 'expanded_label' : false, 'hidden' : true, 'sort_headers' : true },
            'au_barcode' : { 'hidden' : false },
            'au_barred' : { 'hidden' : false },
            'au_family_name' : { 'hidden' : false },
            'au_first_given_name' : { 'hidden' : false },
            'au_second_given_name' : { 'hidden' : false },
            'au_dob' : { 'hidden' : false },
            'au_profile' : { 'fleshed_display_field' : 'name' },
            'au_ident_type' : { 'fleshed_display_field' : 'name' },
            'au_ident_type2' : { 'fleshed_display_field' : 'name' },
            'au_mailing_address' : { 'remove_me' : true },
            'au_billing_address' : { 'remove_me' : true },
            'au_net_access_level' : { 'fleshed_display_field' : 'name' }
        }).concat(
            obj.list.fm_columns('ac',{
                '*' : { 'remove_virtual' : true, 'expanded_label' : true, 'hidden' : true },
                'ac_barcode' : { 'hidden' : false }
            })
        ).concat(
            obj.list.fm_columns('aua',{
                '*' : {
                    'dataobj' : 'billing_aua',
                    'remove_virtual' : true,
                    'label_prefix' : $('patronStrings').getString('staff.patron.search_result.billing_address_column_label_prefix'),
                    'hidden' : true
                }
            },'billing_')
        ).concat(
            obj.list.fm_columns('aua',{
                '*' : {
                    'dataobj' : 'mailing_aua',
                    'remove_virtual' : true,
                    'label_prefix' : $('patronStrings').getString('staff.patron.search_result.mailing_address_column_label_prefix'),
                    'hidden' : true
                }
            },'mailing_')
        );

        obj.dblclick_handler = function(ev) {
            JSAN.use('util.functional');
            var sel = obj.list.retrieve_selection();
            var list = util.functional.map_list(
                sel,
                function(o) { return o.getAttribute('retrieve_id'); }
            );
            obj.controller.view.cmd_sel_clip.setAttribute('disabled', list.length < 1 );
            if (typeof obj.on_dblclick == 'function') {
                obj.on_dblclick(list);
            }
            if (typeof window.xulG == 'object' && typeof window.xulG.on_dblclick == 'function') {
                obj.error.sdump('D_PATRON','patron.search_result: Calling external .on_dblclick()\n');
                window.xulG.on_dblclick(list);
            } else {
                obj.error.sdump('D_PATRON','patron.search_result: No external .on_dblclick()\n');
            }
        };

        obj.list.init(
            {
                'columns' : columns,
                'retrieve_row' : function(params) {
                    var id = params.retrieve_id;
                    var au_obj = patron.util.retrieve_fleshed_au_via_id(
                        ses(),
                        id,
                        ["card","billing_address","mailing_address"],
                        function(req) {
                            try {
                                var row = params.row;
                                if (typeof row.my == 'undefined') row.my = {};
                                row.my.au = req.getResultObject();
                                row.my.ac = row.my.au.card();
                                row.my.billing_aua = row.my.au.billing_address();
                                row.my.mailing_aua = row.my.au.mailing_address();
                                if (typeof params.on_retrieve == 'function') {
                                    params.on_retrieve(row);
                                } else {
                                    alert($("patronStrings").getFormattedString('staff.patron.search_result.init.typeof_params', [typeof params.on_retrieve]));
                                }
                            } catch(E) {
                                alert('error: ' + E);
                            }
                        }
                    );
                },
                'on_dblclick' : obj.dblclick_handler,
                'on_select' : function(ev) {
                    JSAN.use('util.functional');
                    var sel = obj.list.retrieve_selection();
                    var list = util.functional.map_list(
                        sel,
                        function(o) { return o.getAttribute('retrieve_id'); }
                    );
                    obj.controller.view.cmd_sel_clip.setAttribute('disabled', list.length < 1 );
                    if (typeof obj.on_select == 'function') {
                        obj.on_select(list);
                    }
                    if (typeof window.xulG == 'object' && typeof window.xulG.on_select == 'function') {
                        obj.error.sdump('D_PATRON','patron.search_result: Calling external .on_select()\n');
                        window.xulG.on_select(list);
                    } else {
                        obj.error.sdump('D_PATRON','patron.search_result: No external .on_select()\n');
                    }
                }
            }
        );
        JSAN.use('util.controller'); obj.controller = new util.controller();
        obj.controller.init(
            {
                control_map : {
                    'cmd_broken' : [
                        ['command'],
                        function() { alert($("commonStrings").getString('common.unimplemented')); }
                    ],
                    'cmd_search_print' : [
                        ['command'],
                        function() {
                            try {
                                obj.list.dump_csv_to_printer();
                            } catch(E) {
                                obj.error.standard_unexpected_error_alert($("patronStrings").getString('staff.patron.search_result.init.search_print'),E);
                            }
                        }
                    ],
                    'cmd_sel_clip' : [
                        ['command'],
                        function() {
                            try {
                                obj.list.clipboard();
                            } catch(E) {
                                obj.error.standard_unexpected_error_alert($("patronStrings").getString('staff.patron.search_result.init.search_clipboard'),E);
                            }
                        }
                    ],
                    'cmd_save_cols' : [
                        ['command'],
                        function() {
                            try {
                                obj.list.save_columns();
                            } catch(E) {
                                obj.error.standard_unexpected_error_alert($("patronStrings").getString('staff.patron.search_result.init.search_saving_columns'),E);
                            }
                        }
                    ],
                }
            }
        );

        if (obj.query) obj.search(obj.query);
    },

    'cleanup' : function( params ) {
        var obj = this;
        obj.controller.cleanup();
        obj.list.cleanup();
        obj.list.clear();
    },

    'search' : function(query) {
        var obj = this;
        var search_hash = {};
        obj.search_term_count = 0;
        var inactive = false;
        var search_depth = 0;
        for (var i in query) {
            switch( i ) {
                case 'card':
                    search_hash[ i ] = {};
                    search_hash[ i ].value = query[i];
                    search_hash[i].group = 3; 
                    obj.search_term_count++;
                break;

                case 'phone': case 'ident': 
                
                    search_hash[ i ] = {};
                    search_hash[ i ].value = query[i];
                    search_hash[i].group = 2; 
                    obj.search_term_count++;
                break;

                case 'street1': case 'street2': case 'city': case 'state': case 'post_code': 
                
                    search_hash[ i ] = {};
                    search_hash[ i ].value = query[i];
                    search_hash[i].group = 1; 
                    obj.search_term_count++;
                break;

                case 'family_name': case 'first_given_name': case 'second_given_name': case 'email': case 'alias': case 'usrname': case 'profile':

                    search_hash[ i ] = {};
                    search_hash[ i ].value = query[i];
                    search_hash[i].group = 0; 
                    obj.search_term_count++;
                break;

                case 'inactive':
                    if (query[i] == 'checked' || query[i] == 'true') inactive = true;
                break;

                case 'search_depth':
                    search_depth = function(a){return a;}(query[i]);
                break;
            }
        }
        try {
            var results = [];

            var sort_params = obj.search_sort;
            if (!sort_params) {
                sort_params = [ 'family_name ASC', 'first_given_name ASC', 'second_given_name ASC', 'dob DESC' ];
            }
            var params = [ 
                ses(), 
                search_hash, 
                typeof obj.search_limit != 'undefined' && typeof obj.search_limit != 'null' ? obj.search_limit : obj.result_cap + 1, 
                sort_params
            ];
            if (inactive) {
                params.push(1);
                if (document.getElementById('active')) {
                    document.getElementById('active').setAttribute('hidden','false');
                    document.getElementById('active').hidden = false;
                }
            } else {
                params.push(0);
            }
            params.push(search_depth);
            if (obj.search_term_count > 0) {
                //alert('search params = ' + obj.error.pretty_print( js2JSON( params ) ) );
                results = this.network.simple_request( 'FM_AU_IDS_RETRIEVE_VIA_HASH', params );
                if ( results == null ) results = [];
                if (typeof results.ilsevent != 'undefined') throw(results);
                if (results.length == 0) {
                    alert($("patronStrings").getString('staff.patron.search_result.search.no_patrons_found'));
                    return;
                }
                if (results.length == typeof obj.search_limit != 'undefined' && typeof obj.search_limit != 'null' ? obj.search_limit : obj.result_cap+1) {
                    results.pop();
                    alert($("patronStrings").getFormattedString('staff.patron.search_result.search.capped_results', [typeof obj.search_limit != 'undefined' && typeof obj.search_limit != 'null' ? obj.search_limit : obj.result_cap]));
                }
            } else {
                alert($("patronStrings").getString('staff.patron.search_result.search.enter_search_terms'));
                return;
            }

            obj.list.clear();
            //this.list.append( { 'retrieve_id' : results[i], 'row' : {} } );
            var funcs = [];

                function gen_func(r) {
                    return function() {
                        obj.list.append( { 'retrieve_id' : r, 'row' : {}, 'to_bottom' : true, 'no_auto_select' : true } );
                    }
                }

            for (var i = 0; i < results.length; i++) {
                funcs.push( gen_func(results[i]) );
            }
            JSAN.use('util.exec'); var exec = new util.exec(4);
            exec.chain( funcs );

        } catch(E) {
            this.error.standard_unexpected_error_alert('patron.search_result.search',E);
        }
    }

}

dump('exiting patron/search_result.js\n');
