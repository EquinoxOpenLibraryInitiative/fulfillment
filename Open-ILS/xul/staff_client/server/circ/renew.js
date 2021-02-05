dump('entering circ.renew.js\n');

if (typeof circ == 'undefined') circ = {};
circ.renew = function (params) {

    JSAN.use('util.error'); this.error = new util.error();
    JSAN.use('util.network'); this.network = new util.network();
    JSAN.use('util.barcode');
    JSAN.use('util.date');
    this.OpenILS = {}; JSAN.use('OpenILS.data'); this.OpenILS.data = new OpenILS.data(); this.OpenILS.data.init({'via':'stash'});
    this.data = this.OpenILS.data;
}

circ.renew.prototype = {

    'selection_list' : [],

    'init' : function( params ) {

        var obj = this;

        JSAN.use('circ.util'); JSAN.use('patron.util');
        var columns = circ.util.columns( 
            { 
                'barcode' : { 'hidden' : false },
                'title' : { 'hidden' : false },
                'location' : { 'hidden' : false },
                'call_number' : { 'hidden' : false },
                'status' : { 'hidden' : false },
                'alert_message' : { 'hidden' : false },
                'due_date' : { 'hidden' : false },
                'due_time' : { 'hidden' : false },
                'renewal_remaining' : { 'hidden' : false }
            },
            {
                'except_these' : [ 'uses', 'checkin_time_full' ]
            }
        ).concat(
            patron.util.columns( { 'family_name' : { 'hidden' : 'false' } } )

        ).concat(
            patron.util.mbts_columns( {}, { 'except_these' : [ 'total_paid', 'total_owed', 'xact_start', 'xact_finish', 'xact_type' ] } )

        ).sort( function(a,b) { if (a.label < b.label) return -1; if (a.label > b.label) return 1; return 0; } );

        JSAN.use('util.list'); obj.list = new util.list('renew_list');
        obj.list.init(
            {
                'columns' : columns,
                'on_select' : function(ev) {
                    try {
                        JSAN.use('util.functional');
                        var sel = obj.list.retrieve_selection();
                        obj.selection_list = util.functional.map_list(
                            sel,
                            function(o) { return JSON2js(o.getAttribute('retrieve_id')); }
                        );
                        obj.error.sdump('D_TRACE', 'circ/copy_status: selection list = ' + js2JSON(obj.selection_list) );
                        if (obj.selection_list.length == 0) {
                            obj.controller.view.sel_edit.setAttribute('disabled','true');
                            obj.controller.view.sel_opac.setAttribute('disabled','true');
                            obj.controller.view.sel_opac_holds.setAttribute('disabled','true');
                            obj.controller.view.sel_patron.setAttribute('disabled','true');
                            obj.controller.view.sel_last_patron.setAttribute('disabled','true');
                            obj.controller.view.sel_copy_details.setAttribute('disabled','true');
                            obj.controller.view.sel_bucket.setAttribute('disabled','true');
                            obj.controller.view.sel_spine.setAttribute('disabled','true');
                            obj.controller.view.sel_transit_abort.setAttribute('disabled','true');
                            obj.controller.view.sel_clip.setAttribute('disabled','true');
                            obj.controller.view.sel_mark_items_damaged.setAttribute('disabled','true');
                        } else {
                            obj.controller.view.sel_edit.setAttribute('disabled','false');
                            obj.controller.view.sel_opac.setAttribute('disabled','false');
                            obj.controller.view.sel_opac_holds.setAttribute('disabled','false');
                            obj.controller.view.sel_patron.setAttribute('disabled','false');
                            obj.controller.view.sel_last_patron.setAttribute('disabled','false');
                            obj.controller.view.sel_copy_details.setAttribute('disabled','false');
                            obj.controller.view.sel_bucket.setAttribute('disabled','false');
                            obj.controller.view.sel_spine.setAttribute('disabled','false');
                            obj.controller.view.sel_transit_abort.setAttribute('disabled','false');
                            obj.controller.view.sel_clip.setAttribute('disabled','false');
                            obj.controller.view.sel_mark_items_damaged.setAttribute('disabled','false');
                        }
                    } catch(E) {
                        alert('FIXME: ' + E);
                    }
                }
            }
        );
        
        JSAN.use('util.controller'); obj.controller = new util.controller();
        obj.controller.init(
            {
                'control_map' : {
                    'save_columns' : [ [ 'command' ], function() { obj.list.save_columns(); } ],
                    'sel_clip' : [
                        ['command'],
                        function() { 
                            obj.list.clipboard(); 
                            obj.controller.view.renew_barcode_entry_textbox.focus();
                        }
                    ],
                    'sel_edit' : [
                        ['command'],
                        function() {
                            try {
                                obj.spawn_copy_editor();
                            } catch(E) {
                                alert(E);
                            }
                        }
                    ],
                    'sel_spine' : [
                        ['command'],
                        function() {
                            JSAN.use('cat.util');
                            cat.util.spawn_spine_editor(obj.selection_list);
                        }
                    ],
                    'sel_opac' : [
                        ['command'],
                        function() {
                            JSAN.use('cat.util');
                            cat.util.show_in_opac(obj.selection_list);
                        }
                    ],
                    'sel_opac_holds' : [
                        ['command'],
                        function() {
                            JSAN.use('cat.util');
                            cat.util.show_in_opac(obj.selection_list,{default_view:'hold_browser'});
                        }
                    ],
                    'sel_transit_abort' : [
                        ['command'],
                        function() {
                            JSAN.use('circ.util');
                            circ.util.abort_transits(obj.selection_list);
                        }
                    ],
                    'sel_patron' : [
                        ['command'],
                        function() {
                            JSAN.use('circ.util');
                            circ.util.show_last_few_circs(obj.selection_list);
                        }
                    ],
                    'sel_last_patron' : [
                        ['command'],
                        function() {
                            var patrons = {};
                            for (var i = 0; i < obj.selection_list.length; i++) {
                                var circs = obj.network.simple_request('FM_CIRC_RETRIEVE_VIA_COPY',[ses(),obj.selection_list[i].copy_id,1]);
                                if (circs.length > 0) {
                                    if (circs[0].usr()) {
                                        patrons[circs[0].usr()] = 1;
                                    } else {
                                        alert(
                                            document.getElementById('circStrings')
                                            .getFormattedString(
                                                'staff.circ.item_no_user', 
                                                [obj.selection_list[i].barcode])
                                        );
                                    }
                                } else {
                                    alert(document.getElementById('circStrings').getFormattedString('staff.circ.item_no_circs', [obj.selection_list[i].barcode]));
                                }
                            }
                            for (var i in patrons) {
                                xulG.new_patron_tab({},{'id' : i});
                            }
                        }
                    ],
                    'sel_copy_details' : [
                        ['command'],
                        function() {
                            JSAN.use('circ.util');
                            circ.util.item_details_new(
                                util.functional.map_list(
                                    obj.selection_list,
                                    function(o) { return o.barcode; }
                                )
                            );
                        }
                    ],
                    'sel_mark_items_damaged' : [
                        ['command'],
                        function() {
                            var funcs = [];
                            JSAN.use('cat.util'); JSAN.use('util.functional');
                            cat.util.mark_item_damaged( util.functional.map_list( obj.selection_list, function(o) { return o.copy_id; } ) );
                        }
                    ],
                    'sel_bucket' : [
                        ['command'],
                        function() {
                            JSAN.use('cat.util');
                            cat.util.add_copies_to_bucket(obj.selection_list);
                        }
                    ],
                    'renew_barcode_entry_textbox' : [
                        ['keypress'],
                        function(ev) {
                            if (ev.keyCode && ev.keyCode == 13) {
                                obj.renew();
                            }
                        }
                    ],
                    'cmd_broken' : [
                        ['command'],
                        function() { alert(document.getElementById('circStrings').getString('staff.circ.unimplemented')); }
                    ],
                    'cmd_renew_submit_barcode' : [
                        ['command'],
                        function() {
                            obj.renew();
                        }
                    ],
                    'cmd_renew_print' : [
                        ['command'],
                        function() {
                            var p = { 
                                'printer_context' : 'receipt',
                                'template' : 'renew'
                            };
                            obj.list.print(p);
                        }
                    ],
                    'cmd_csv_to_clipboard' : [ ['command'], function() { 
                        obj.list.dump_csv_to_clipboard(); 
                        obj.controller.view.renew_barcode_entry_textbox.focus();
                    } ],
                    'cmd_csv_to_printer' : [ ['command'], function() { 
                        obj.list.dump_csv_to_printer(); 
                        obj.controller.view.renew_barcode_entry_textbox.focus();
                    } ],
                    'cmd_csv_to_file' : [ ['command'], function() { 
                        obj.list.dump_csv_to_file( { 'defaultFileName' : 'checked_in.txt' } ); 
                        obj.controller.view.renew_barcode_entry_textbox.focus();
                    } ],
                    'renew_duedate_datepicker' : [
                        ['change'],
                        function(ev) { 
                            try {
                                if (obj.check_date(ev.target)) {
                                    ev.target.parentNode.setAttribute('style','');
                                } else {
                                    ev.target.parentNode.setAttribute('style','background-color: red');
                                }
                            } catch(E) {
                                alert('Error in renew.js, renew_duedate_datepicker @change: ' + E);
                            }
                        }
                    ]

                }
            }
        );
        this.controller.render();
        this.controller.view.renew_barcode_entry_textbox.focus();

    },

    'test_barcode' : function(bc) {
        var obj = this;
        var x = document.getElementById('strict_barcode');
        if (x && x.checked != true) return true;
        var good = util.barcode.check(bc);
        if (good) {
            return true;
        } else {
            if ( 1 == obj.error.yns_alert(
                        document.getElementById('circStrings').getFormattedString('staff.circ.check_digit.bad', [bc]),
                        document.getElementById('circStrings').getString('staff.circ.barcode.bad'),
                        document.getElementById('circStrings').getString('staff.circ.cancel'),
                        document.getElementById('circStrings').getString('staff.circ.barcode.accept'),
                        null,
                        document.getElementById('circStrings').getString('staff.circ.confirm'),
                        '/xul/server/skin/media/images/bad_barcode.png'
            ) ) {
                return true;
            } else {
                return false;
            }
        }
    },

    'renew' : function(params) {
        var obj = this;
        try {
            if (!params) params = {};

            var barcode = obj.controller.view.renew_barcode_entry_textbox.value;
            if (!barcode) return;
            if (barcode) {
                if ( obj.test_barcode(barcode) ) { /* good */ } else { /* bad */ return; }
            }
            params.barcode = barcode;
            params.return_patron = true;

            var auto_print = document.getElementById('renew_auto');
            if (auto_print) auto_print = auto_print.checked;

            if (document.getElementById('renew_duedate_checkbox').checked) {
                if (! obj.check_date(obj.controller.view.renew_duedate_datepicker)) return;
                var tp = document.getElementById('renew_duedate_timepicker');
                var dp = obj.controller.view.renew_duedate_datepicker;
                var tp_date = tp.dateValue;
                var dp_date = dp.dateValue;
                dp_date.setHours( tp_date.getHours() );
                dp_date.setMinutes( tp_date.getMinutes() );

                JSAN.use('util.date');
                params.due_date = util.date.formatted_date(dp_date,'%{iso8601}');
            }


            JSAN.use('circ.util');
            var renew = circ.util.renew_via_barcode(
                params,
                function( r ) {
                    obj.renew_followup( r, barcode );
                }
            );
        } catch(E) {
            obj.error.standard_unexpected_error_alert('Error in circ/renew.js, renew():', E);
            if (typeof obj.on_failure == 'function') {
                obj.on_failure(E);
            }
            if (typeof window.xulG == 'object' && typeof window.xulG.on_failure == 'function') {
                window.xulG.on_failure(E);
            }
        }
    },

    'renew_followup' : function(r,bc) {
        var obj = this;
        try {
            if (!r) return obj.on_failure(); /* circ.util.renew handles errors and returns null currently */
            if ( (typeof r[0].ilsevent != 'undefined' && r[0].ilsevent == 0) ) {
                // SUCCESS
                var x = document.getElementById('no_change_label');
                if (x) {
                    x.hidden = true;
                    x.setAttribute('value','');
                }
            } else {
                // FAILURE
                var msg = document.getElementById("patronStrings").getFormattedString('staff.patron.items.items_renew.not_renewed',[bc, r[0].textcode + r[0].desc]);
                var x = document.getElementById('no_change_label');
                if (x) {
                    x.hidden = false;
                    x.setAttribute('value',msg);
                }
                obj.controller.view.renew_barcode_entry_textbox.focus();
                obj.controller.view.renew_barcode_entry_textbox.select();
                return;
            }
            var renew = r[0].payload;
            var retrieve_id = js2JSON( { 'copy_id' : renew.copy.id(), 'barcode' : renew.copy.barcode(), 'doc_id' : (renew.record == null ? null : renew.record.doc_id() ) } );
            if (document.getElementById('trim_list')) {
                var x = document.getElementById('trim_list');
                if (x.checked) { obj.list.trim_list = 20; } else { obj.list.trim_list = null; }
            }

            var params = {
                'retrieve_id' : retrieve_id,
                'row' : {
                    'my' : {
                        'circ' : renew.circ,
                        'mbts' : renew.parent_circ ? renew.parent_circ.billable_transaction().summary() : null,
                        'mvr' : renew.record,
                        'acp' : renew.copy,
                        'acn' : renew.volume,
                        'au' : renew.patron,
                        'status' : renew.status,
                        'route_to' : renew.route_to,
                        'message' : renew.message
                    }
                },
                'to_top' : true
            };
            obj.list.append( params );

            if (params.row.my.mbts && ( document.getElementById('no_change_label') || document.getElementById('fine_tally') ) ) {
                JSAN.use('util.money');
                var bill = params.row.my.mbts;
                if (Number(bill.balance_owed()) != 0) {
                    if (document.getElementById('no_change_label')) {
                        var m = document.getElementById('no_change_label').getAttribute('value');
                        document.getElementById('no_change_label').setAttribute(
                            'value', 
                            m + document.getElementById('circStrings').getFormattedString('staff.circ.utils.billable.amount', [params.row.my.acp.barcode(), util.money.sanitize(bill.balance_owed())]) + '  '
                        );
                        document.getElementById('no_change_label').setAttribute('hidden','false');
                    }
                    if (document.getElementById('fine_tally')) {
                        var amount = Number( document.getElementById('fine_tally').getAttribute('amount') ) + Number( bill.balance_owed() );
                        document.getElementById('fine_tally').setAttribute('amount',amount);
                        document.getElementById('fine_tally').setAttribute(
                            'value',
                            document.getElementById('circStrings').getFormattedString('staff.circ.utils.fine_tally_text', [ util.money.sanitize( amount ) ])
                        );
                        document.getElementById('fine_tally').setAttribute('hidden','false');
                    }
                }
            }

            obj.list.node.view.selection.select(0);

            JSAN.use('util.sound'); var sound = new util.sound(); sound.circ_good();

            if (typeof obj.on_renew == 'function') {
                obj.on_renew(renew);
            }
            if (typeof window.xulG == 'object' && typeof window.xulG.on_renew == 'function') {
                window.xulG.on_renew(renew);
            }

            return true;

        } catch(E) {
            obj.error.standard_unexpected_error_alert('Error in circ/renew.js, renew_followup():', E);
            if (typeof obj.on_failure == 'function') {
                obj.on_failure(E);
            }
            if (typeof window.xulG == 'object' && typeof window.xulG.on_failure == 'function') {
                window.xulG.on_failure(E);
            }
        }

    },

    'on_renew' : function() {
        try {
            this.controller.view.renew_barcode_entry_textbox.disabled = false;
            this.controller.view.renew_barcode_entry_textbox.select();
            this.controller.view.renew_barcode_entry_textbox.value = '';
            this.controller.view.renew_barcode_entry_textbox.focus();
        } catch(E) {
            alert('Error in renew.js, on_renew(): ' + E);
        }
    },

    'on_failure' : function() {
        try {
            this.controller.view.renew_barcode_entry_textbox.disabled = false;
            this.controller.view.renew_barcode_entry_textbox.select();
            this.controller.view.renew_barcode_entry_textbox.focus();
        } catch(E) {
            alert('Error in renew.js, on_failure(): ' + E);
        }
    },
    
    'spawn_copy_editor' : function() {

        var obj = this;

        JSAN.use('util.functional');

        var list = obj.selection_list;

        list = util.functional.map_list(
            list,
            function (o) {
                return o.copy_id;
            }
        );

        JSAN.use('cat.util'); cat.util.spawn_copy_editor( { 'copy_ids' : list, 'edit' : 1 } );

    },

    'check_date' : function(node) {
        var obj = this;
        JSAN.use('util.date');
        try {
            obj.controller.view.renew_barcode_entry_textbox.setAttribute('disabled','false');
            obj.controller.view.renew_barcode_entry_textbox.disabled = false;
            obj.controller.view.cmd_renew_submit_barcode.setAttribute('disabled','false');
            obj.controller.view.cmd_renew_submit_barcode.disabled = false;
            if (util.date.check_past('YYYY-MM-DD',node.value) ) {
                obj.controller.view.renew_barcode_entry_textbox.setAttribute('disabled','true');
                obj.controller.view.cmd_renew_submit_barcode.setAttribute('disabled','true');
                return false;
            }
            return true;
        } catch(E) {
            throw(E);
        }
    }

}

dump('exiting circ.renew.js\n');
