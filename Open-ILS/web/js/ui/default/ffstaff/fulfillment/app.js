/**
 * FulfILLment application.
 * Includes pending items, inbound/outbound transits, on shelf,
 * circulating, item status, and bib record file upload.
 */

angular.module('ffMain', 
['ngRoute', 'ui.bootstrap', 'egCoreMod', 'egUiMod', 'egUserMod', 'egListMod'])

.config(function($routeProvider, $locationProvider) {
    $locationProvider.html5Mode(true);
    var resolver = {delay : function(egStartup) {return egStartup.go()}};

    // record management UI
    $routeProvider.when('/fulfillment/records', {
        templateUrl: './fulfillment/t_records',
        controller: 'RecordsCtrl',
        resolve : resolver
    });

    // item status by barcode
    $routeProvider.when('/fulfillment/status/:barcode/:owner', {
        templateUrl: './fulfillment/t_ill',
        controller: 'ILLCtrl',
        resolve : resolver
    });

   // item status by barcode
    $routeProvider.when('/fulfillment/status/:barcode', {
        templateUrl: './fulfillment/t_ill',
        controller: 'ILLCtrl',
        resolve : resolver
    });

    // item status, barcode pending
    $routeProvider.when('/fulfillment/status', {
        templateUrl: './fulfillment/t_ill',
        controller: 'ILLCtrl',
        resolve : resolver
    });

   // single scan by barcode
    $routeProvider.when('/fulfillment/singlescan/:barcode', {
        templateUrl: './fulfillment/t_ill',
        controller: 'ILLCtrl',
        resolve : resolver
    });

    // single scan, barcode pending
    $routeProvider.when('/fulfillment/singlescan', {
        templateUrl: './fulfillment/t_ill',
        controller: 'ILLCtrl',
        resolve : resolver
    });

    // transaction-focused tabs
    $routeProvider.when('/fulfillment/:orientation/:tab', {
        templateUrl: './fulfillment/t_ill',
        controller: 'ILLCtrl',
        resolve : resolver
    });

    // Default to ILL management tabs
    $routeProvider.otherwise({
        redirectTo : '/fulfillment/borrower/pending'
    });
})

/**
 * orgSelector service
 */
.factory('orgSelector', 
       ['$rootScope','egOrg','egAuth', 
function($rootScope,  egOrg,  egAuth) {
    return {
        all : function(newList) {
            if (newList) {
                this._all = newList;
            } else if (!this._all) {
                this._all = egOrg.list();
            } 
            return this._all;
        },

        // currently selected org unit
        current : function(id) {
            if (id) {
                this.org = id;
            } else if (!this.org) {
                this.org = egAuth.user().ws_ou();
            }
            return egOrg.get(this.org);
        },

        /** returns list of IDs for all org units within the
         * full path of current.  Useful for pcrud queries.
         */
        relatedOrgs : function(id) {
            return egOrg.fullPath(
                this.current()).map(function(o) {return o.id()});
        }
    }
}])

/**
 * Top-level page controller.  Handles global components, like the org 
 * selector.
 */
.controller('FFMainCtrl', 
        ['$scope','$route','egStartup','orgSelector','egAuth','egUser',
function ($scope,  $route,  egStartup,  orgSelector,  egAuth,  egUser) {

    // run after startup so we can guarantee access to org units
    egStartup.go().then(function() {
        // after startup, we want to fetch the perm orgs for our 
        // logged in user.  From there, we can drive the org selector
        egUser.hasPermAt('FULFILLMENT_ADMIN') 
        .then(function(orgList) {
            orgSelector.all(orgList);
            $scope.orgSelector = orgSelector;
        });
    });

    // change the selected org unit and re-draw the page
    $scope.selectOrg = function(id) {
        orgSelector.current(id);
        $route.reload();
    }

    $scope.logout = function() {
        egAuth.logout();
        return true;
    };
}])


/**
 * Main ILL controller.
 * Maintains the table data / attributes.
 * Performs actions.
 */
.controller('ILLCtrl', 
        ['$scope','$q','$compile','$timeout','$rootScope','$location','$modal',
         '$route','$routeParams','egNet','egAuth','orgSelector','egOrg','egList',
function ($scope,  $q,  $compile,  $timeout,  $rootScope, $location, $modal,
          $route,  $routeParams,  egNet,  egAuth,  orgSelector,  egOrg,  egList) {

    $scope.tabname = $routeParams.tab;
    $scope.orientation = $routeParams.orientation;

    // URL format for /status needs a wee bit of manual handling
    if (!$scope.tabname) $scope.tabname = 'status';
    if ($location.path().match(/singlescan/)) $scope.tabname = 'singlescan';

    // bools useful for templates
    $scope['tab_' + $scope.tabname] = true;
    $scope['orientation_' + $scope.orientation] = true;

    // so our child controllers can access our route info
    $scope.illRouteParams = $routeParams;

    $scope.itemList = egList.create({limit : 10}); // UI?
    $scope.columns = [];
    $scope.addColumn = function(col) {
        $scope.columns.push(col);
    }

    // sort by column name. if already sorting on the selected column,
    // sort 'desc' instead.
    $scope.sort = function(colname) {
        if (typeof $scope.itemList.sort == 'string' &&
                $scope.itemList.sort == colname) {
            $scope.itemList.sort = {};
            $scope.itemList.sort[colname] = 'desc';
        } else {
            $scope.itemList.sort = colname;
        }
        $scope.collect();
    }

    // map of flattener fields to retrieve for each query type
    // TODO: there's some duplication here, since the fields
    // are also defined in the template.
    $scope.flatFields = {
        ahr : {
            id : 'id',
            hold_id : 'id',
            target : 'target',
            hold_type : 'hold_type',
            request_time : 'request_time',
            frozen : 'frozen',
            expire_time : 'expire_time',
            patron_id : 'usr.id',
            patron_barcode : 'usr.card.barcode',
            patron_given_name : 'usr.first_given_name',
            patron_family_name : 'usr.family_name',
            hold_request_lib : 'request_lib.shortname',
            hold_pickup_lib : 'pickup_lib.shortname',
            hold_shelf_time : 'shelf_time',
            hold_shelf_expire_time : 'shelf_expire_time',
            title : 'bib_rec.bib_record.simple_record.title',
            author : 'bib_rec.bib_record.simple_record.author',
            copy_id : 'current_copy.id',
            copy_status : 'current_copy.status.name',
            copy_barcode : 'current_copy.barcode',
            copy_circ_lib_id : 'current_copy.circ_lib.id',
            copy_circ_lib : 'current_copy.circ_lib.shortname',
            call_number : 'current_copy.call_number.label'
        },
        circ : {
            id : 'id',
            circ_id : 'id',
            patron_id : 'usr.id',
            patron_barcode : 'usr.card.barcode',
            patron_given_name : 'usr.first_given_name',
            patron_family_name : 'usr.family_name',
            title : 'target_copy.call_number.record.simple_record.title',
            author : 'target_copy.call_number.record.simple_record.author',
            copy_id : 'target_copy.id',
            copy_status : 'target_copy.status.name',
            copy_barcode : 'target_copy.barcode',
            copy_circ_lib_id : 'target_copy.circ_lib.id',
            copy_circ_lib : 'target_copy.circ_lib.shortname',
            call_number : 'target_copy.call_number.label',
            circ_circ_lib : 'circ_lib.shortname',
            due_date : 'due_date',
            xact_start : 'xact_start',
            checkin_time : 'checkin_time'
        },
        atc : {
            id : 'id',
            transit_id : 'id',
            hold_id : 'hold_transit_copy.hold.id',
            hold_request_lib : 'hold_transit_copy.hold.request_lib.shortname',
            hold_pickup_lib : 'hold_transit_copy.hold.pickup_lib.shortname',
            patron_id : 'hold_transit_copy.hold.usr.id',
            patron_barcode : 'hold_transit_copy.hold.usr.card.barcode',
            patron_given_name : 'hold_transit_copy.hold.usr.first_given_name',
            patron_family_name : 'hold_transit_copy.hold.usr.family_name',
            title : 'target_copy.call_number.record.simple_record.title',
            routing_code : 'dest.routing_code',
            author : 'target_copy.call_number.record.simple_record.author',
            copy_status : 'target_copy.status.name',
            copy_id : 'target_copy.id',
            copy_barcode : 'target_copy.barcode',
            copy_circ_lib_id : 'target_copy.circ_lib.id',
            copy_circ_lib : 'target_copy.circ_lib.shortname',
            call_number : 'target_copy.call_number.label',
            transit_time : 'source_send_time',
            transit_source : 'source.shortname',
            transit_dest : 'dest.shortname'
        }
    };

    // apply the route-specific data loading class/query
    // query == flattener query
    $scope.setCollector = function(class_, query) {
        $scope.collector = {
            query : query,
            class_ : class_
        }
    }

    // called on each item as it's received
    $scope.setMunger = function(func) {
        $scope.munger = func;
    }

    // table paging...
    $scope.firstPage = function() {
        $scope.itemList.offset = 0;
        $scope.collect();
    };

    $scope.nextPage = function() {
        $scope.itemList.incrementPage();
        $scope.collect();
    };

    $scope.prevPage = function() {
        $scope.itemList.decrementPage();
        $scope.collect();
    };

    // fire the flattened search query to collect items
    $scope.collect = function() {
        $scope.lookupComplete = false;
        $scope.itemList.resetPageData();
        egNet.request(
            'open-ils.fielder',
            'open-ils.fielder.flattened_search',
            egAuth.token(), 
            $scope.collector.class_,
            $scope.flatFields[$scope.collector.class_],
            $scope.collector.query,
            {   sort : [$scope.itemList.sort],
                limit : $scope.itemList.limit,
                offset : $scope.itemList.offset
            }
        ).then(
            function() { $scope.lookupComplete = true },
            null, // error
            function(item) { // notify/onresponse handler
                item.index = $scope.itemList.count();
                if (item.copy_barcode) {
                    item.copy_barcode_enc = 
                        encodeURIComponent(item.copy_barcode);
		    //var cbar = item.copy_barcode_enc;
                    //item.copy_barcode_enc =
                    //    cbar.replace("%2F", "%252F");
                }
                if ($scope.munger) $scope.munger(item);
                $scope.itemList.items.push(item);
            }
        );
    }


    // Actions
    // Performed on flattened items
    $scope.actions = {};

    $scope.actions.checkin = function(item) {
        $scope.action_pending = true;
        var deferred = $q.defer();
        egNet.request('open-ils.circ', 
            'open-ils.circ.checkin.override',
            egAuth.token(), {
                circ_lib : orgSelector.current().id(),
                copy_id: item.copy_id, ff_action: item.next_action
            }
        ).then(function(response) {
            $scope.action_pending = false;
            // do some basic sanity checking before passing 
            // the response to the caller.
            if (response) {
                if (angular.isArray(response))
                    response = response[0];
                // TODO: check for failure events
                deferred.resolve(response);
            } else {
                // warn that checkin failed
                deferred.reject();
            }
        });
        return deferred.promise;
    }

    $scope.actions.checkout = function(item) {
        $scope.action_pending = true;
        var deferred = $q.defer();
        egNet.request('open-ils.circ', 
            'open-ils.circ.checkout.full.override',
            egAuth.token(), {
                circ_lib : orgSelector.current().id(),
                patron_id : item.patron_id,
                copy_id: item.copy_id,
                ff_action: item.next_action
            }
        ).then(function(response) {
            $scope.action_pending = false;
            // do some basic sanity checking before passing 
            // the response to the caller.
            if (response) {
                if (angular.isArray(response))
                    response = response[0];
                // TODO: check for failure events
                deferred.resolve(response);
            } else {
                // warn that checkin failed
                deferred.reject();
            }
        });
        return deferred.promise;
    }


    $scope.actions.cancel = function(item) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request('open-ils.circ', 
            'open-ils.circ.hold.cancel',
            egAuth.token(), item.hold_id
        ).then(function() {
            $scope.action_pending = false;
            deferred.resolve();
        });
        return deferred.promise;
    }

    $scope.actions.retarget = function(item) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request('open-ils.circ', 
            'open-ils.circ.hold.reset',
          egAuth.token(), item.hold_id
        ).then(function() {
            $scope.action_pending = false;
            deferred.resolve();
        });
        return deferred.promise;
    }

    $scope.actions.popup_abort_block_ill = function(item) {
        return $scope.actions.popup_block_ill(item, null, true);
    }

    $scope.actions.popup_block_ill = function(item, s, abort_transit) {
        var outer = $scope;
        return $modal.open({
            templateUrl: './fulfillment/t_block_ill',
            controller:
                ['$scope', '$modalInstance', function($scope, $modalInstance) {
                $scope.item = item;
                $scope.block_reason = 'policy';
                $scope.block_all = true;

                $scope.$watch('block_reason', function(n,o) {
                    if (n != o && n == 'policy') {
                        $scope.block_all = true;
                    }
                });

                $scope.ok = function() {
                    var promise;
                    if (abort_transit) {
                        promise = outer.actions.abort_transit(item);
                    } else {
                        promise = $q.when();
                    }

                    outer.actionPending = true;
                    if ($scope.block_all) {
                        console.log('blocking all holds');
                        return promise.then(
                            function () {
                                outer.actions.block_all(item,{block_all_reason:$scope.block_reason})
                                    .then(function() { outer.action_pending = false; $modalInstance.close() })
                            }
                        );
                    } else {
                        console.log('blocking one hold: ' + item.hold_id);
                        return promise.then(
                            function () {
                                outer.actions.block_one(item,{block_one_reason:$scope.block_reason})
                                    .then(function() { outer.action_pending = false; $modalInstance.close() })
                            }
                        );
                    }
                }

                $scope.cancel = function () { outer.action_pending = false; $modalInstance.dismiss() }
            }]
        }).result;
    }

    $scope.actions.block_one = function(item,scope) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request('open-ils.circ', 
            'open-ils.circ.hold.block',
          egAuth.token(), item.copy_id, scope.block_one_reason, item.hold_id
        ).then(function() {
            $scope.action_pending = false;
            deferred.resolve();
        });
        return deferred.promise;
    }

    $scope.actions.unblock_all = function(item,scope) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request('open-ils.circ', 
            'open-ils.circ.hold.unblock',
          egAuth.token(), item.copy_id
        ).then(function() {
            $scope.action_pending = false;
            deferred.resolve();
        });
        return deferred.promise;
    }

    $scope.actions.block_all = function(item,scope) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request('open-ils.circ', 
            'open-ils.circ.hold.block',
          egAuth.token(), item.copy_id, scope.block_all_reason
        ).then(function() {
            $scope.action_pending = false;
            deferred.resolve();
        });
        return deferred.promise;
    }

    function toggleHoldActive(item, frozen) {
        if (item.frozen == frozen) return $q.when();
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request(
            'open-ils.circ', 
            'open-ils.circ.hold.update.batch',
            egAuth.token(), null, 
            [{id : item.hold_id, frozen : frozen}]
        ).then(function() {
            $scope.action_pending = false;
            deferred.resolve();
        });
        return deferred.promise;
    }

    $scope.actions.activate_hold = function(item) {
        return toggleHoldActive(item, 'f');
    }

    $scope.actions.suspend_hold = function(item) {
        return toggleHoldActive(item, 't');
    }

    $scope.actions.abort_transit = function(item) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request('open-ils.circ', 
            'open-ils.circ.transit.abort',
            egAuth.token(), {transitid : item.transit_id}
        ).then(function() {
            $scope.action_pending = false;
            deferred.resolve();
        });
        return deferred.promise;
    }

    $scope.actions.mark_lost = function(item) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        egNet.request('open-ils.circ', 
            'open-ils.circ.circulation.set_lost',
            egAuth.token(), {barcode : item.item_barcode}
        ).then(function(resp) {
            $scope.action_pending = false;
            if (resp == 1) {
                deferred.resolve();
            } else {
                console.error('mark lost failed: ' + js2JSON(resp));
                deferred.reject();
            }
        });
        return deferred.promise;
    }

    $scope.actions.print = function(item) {
        var deferred = $q.defer();
        $scope.action_pending = true;
        var focus = item.hold ? 'hold' :
            (item.circ ? 'circ' : (item.transit ? 'transit' : 'copy'));

        // TODO: line up print template variables with
        // local data structures
        item.barcode = item.copy_barcode || item.item_barcode;
        item.status = item.status_str || item.copy_status;
        item.item_circ_lib = item.copy_circ_lib || item.circ_lib;

        egNet.request(
            'open-ils.actor',
            'open-ils.actor.web_action_print_template.fetch',
            orgSelector.current().id(), focus
        ).then(function(template) {

            if (!template || !(template = template.template())) { // assign
                console.warn('unable to find template for ' + 
                    item.copy_barcode + ' : ' + focus);
                return;
            }

            // TODO: templates stored for now as dojo-style
            // template.  mangle to angular templates manually.
            template = template.replace(/\${([^}]+)}/g, '{{$1}}');

            // compile the template w/ a temporary print scope
            var printScope = $rootScope.$new();
            angular.forEach(item, function(val, key) {
                printScope[key] = val;
            });
            var element = angular.element(template);
            $compile(element)(printScope);

            // append the compiled element to the new window and print
            var w = window.open();
            $(w.document.body).append(element);
            w.document.close();
            
            // $timeout needed in some environments (Mac confirmed) 
            // to allow the new window to fully $digest() before printing.
            $timeout(
                function() {
                    w.print();
                    w.close();
                    $scope.action_pending = false;
                    deferred.resolve();
                }
            );
        });
        return deferred.promise;
    }

    // default batch action handlers.
    function performOneAction(action, item) {
        console.debug(item.index + ' => ' + action);
        return $scope.actions[action](item).then(
            function(resp) {console.debug(item.index + ' => ' + action + ' : done')}, 
            function(resp) {console.error("error in " + action + " : " + resp)}
        );
    }

    angular.forEach(
        Object.keys($scope.actions),
        function(action) {
            $scope[action] = function() {
                var promises = [];
                angular.forEach(
                    $scope.itemList.selectedItems(),
                    function(item) {
                        promises.push(performOneAction(action, item))
                    }
                );
                // when a batch has successfully completed, 
                // reload the route, unless printing.
                $q.all(promises).then(function() { 
                    if (action != 'print') $route.reload();
                });
            }
        }
    );
}])

.controller('PendingRequestsCtrl',
        ['$scope','$q','$route','egNet','egAuth','egPCRUD','egOrg','orgSelector',
function ($scope,  $q,  $route,  egNet,  egAuth,  egPCRUD,  egOrg,  orgSelector) {

    $scope.itemList.sort = 'request_time';
    $scope.authtoken = egAuth.token();

    var fullPath = orgSelector.relatedOrgs();

    var query = {   
        capture_time : null, 
        cancel_time : null
    };

    if ($scope.orientation_borrower) {
        // holds for my patrons originate "here"
        // current_copy is not relevant
        query.request_lib = fullPath;
    } else {
        // holds for other originate from not-"here" and
        // have a current copy at "here".
        query.request_lib = {'not in' : fullPath};
        query.current_copy = {
            "in" : {
                select: {acp : ['id']},
                from : 'acp',
                where: {
                    deleted : 'f',
                    circ_lib : fullPath,
                    id : {'=' : {'+ahr' : 'current_copy'}}
                }
            }
        }
    }

    $scope.setCollector('ahr', query);
    $scope.setMunger(function(item) {
        item.hold = item.id;
        if ($scope.orientation_lender) 
            item.next_action = 'ill-home-capture';
    });

    $scope.collect();
}])


.controller('TransitsCtrl',
        ['$scope','$q','egPCRUD','orgSelector',
function ($scope,  $q,  egPCRUD,  orgSelector) {

    $scope.itemList.sort = 'transit_time';
    var fullPath = orgSelector.relatedOrgs();
    var dest = fullPath; // inbound transits
    var circ_lib = fullPath; // our copies
    var source = fullPath;  // source of transit

    if ($scope.orientation_borrower) {
        // borrower always means not-our-copies
        circ_lib = {'not in' : fullPath};
    }
    if ($scope.tab_outbound) {
        // outbound transits away from "here"
        dest = {'not in' : fullPath};
    }
    if ($scope.tab_inbound) {
        // in bound transits are to "here"
        source = {'not in' : fullPath};
    }
        
    var query = {
        dest_recv_time : null,
        dest : dest,
	source : source,
        target_copy : {
            'in' : {
                select: {acp : ['id']},
                from : 'acp',
                where : {
                    deleted : 'f',
                    id : {'=' : {'+atc' : 'target_copy'}},
                    circ_lib : circ_lib
                }
            }
        }
    };

    $scope.setCollector('atc', query);
    $scope.setMunger(function(item) {
        if ($scope.tab_inbound) {
            if ($scope.orientation_borrower) {
                item.next_action = 'ill-foreign-receive';
            } else {
                item.next_action = 'transit-home-receive';
            }
        } 
    });

    return $scope.collect();
}])

.controller('OnShelfCtrl',
        ['$scope','$q','egPCRUD','orgSelector',
function ($scope,  $q,  egPCRUD,  orgSelector) {

    $scope.itemList.sort = 'shelf_time';

    var fullPath = orgSelector.relatedOrgs();

    var copy_lib = {'not in' : fullPath}; // not our copy
    var shelf_lib = fullPath; // on our shelf

    if ($scope.orientation_lender) {
        shelf_lib = {'not in' : fullPath};
        copy_lib = fullPath;
    }
        
    var query = {
        frozen : 'f',
        cancel_time : null,
        fulfillment_time : null,
        shelf_time : {'!=' : null},
        current_shelf_lib : shelf_lib,
        current_copy : {
            'in' : {
                select: {acp : ['id']},
                from : 'acp',
                where : {
                    deleted : 'f',
                    id : {'=' : {'+ahr' : 'current_copy'}},
                    circ_lib : copy_lib,
                    status : 8 // On Holds Shelf
                }
            }
        }
    };

    $scope.setCollector('ahr', query);
    $scope.setMunger(function(item) {
        if ($scope.orientation_borrower) {
            item.next_action = 'ill-foreign-checkout';
        }
    });

    return $scope.collect();
}])


.controller('CircCtrl',
        ['$scope','$q','egPCRUD','orgSelector','egNet','egAuth',
function ($scope,  $q,  egPCRUD,  orgSelector,  egNet,  egAuth) {

    $scope.itemList.sort = 'xact_start';

    var fullPath = orgSelector.relatedOrgs();

    var copy_circ_lib = fullPath; // our copies
    var circ_circ_lib = fullPath; // circulating here

    if ($scope.orientation_lender) {
        // circulating elsewhere
        circ_circ_lib = {'not in' : fullPath};
    } else {
        // borrower always means not-our-copies
        copy_circ_lib = {'not in' : fullPath};
    }
        
    var query = {
        checkin_time : null,
        circ_lib : circ_circ_lib,
        target_copy : {
            'in' : {
                select: {acp : ['id']},
                from : 'acp',
                where : {
                    deleted : 'f',
                    id : {'=' : {'+circ' : 'target_copy'}},
                    circ_lib : copy_circ_lib
                }
            }
        }
    };

    $scope.setCollector('circ', query);
    $scope.setMunger(function(item) {
        if ($scope.orientation_borrower) {
            item.next_action = 'ill-foreign-checkin';
        }
    });

    return $scope.collect();
}])


.controller('ItemStatusCtrl',
        ['$scope','$q','$route','$location','egPCRUD','orgSelector','egNet','egAuth','egOrg',
function ($scope,  $q,  $route,  $location,  egPCRUD,  orgSelector,  egNet,  egAuth,  egOrg) {
    $scope.focusMe = true;
    $scope.block_all_reason = 'policy';
    $scope.block_one_reason = 'policy';

    // TODO: can we trim this down?
    function flattenItem(item, item_data) {
        var copy = item_data.copy;
        var transit = item_data.transit;
        var circ = item_data.circ;
        var hold = item_data.hold;
        if (hold) {
            if (!transit && hold.transit()) {
                transit = item_data.hold.transit();
            }
        } else if (transit && transit.hold_transit_copy()) {
            hold = transit.hold_transit_copy().hold();
        }

        item.copy = item_data.copy;
        item.copy_id = item_data.copy.id();
        item.item_barcode = copy.barcode();
        item.item_barcode_enc = encodeURIComponent(copy.barcode());
        var copybar = item.copy_barcode_enc;
        item.circ_lib = egOrg.get(copy.circ_lib()).shortname();
        item.title = copy.call_number().record().simple_record().title();
        item.author = copy.call_number().record().simple_record().author();
        item.call_number = copy.call_number().label();
        item.bib_id = copy.call_number().record().id();
        item.remote_bib_id = copy.call_number().record().remote_id();
        item.next_action = item_data.next_action;
        item.can_cancel_hold = (item_data.can_cancel_hold == 1);
        item.can_retarget_hold = (item_data.can_retarget_hold == 1);

        egPCRUD.search('acbh',{item:item.copy_id, hold:null})
            .then(null,null,function(block) {
                item.blocked = true;
            });

        switch(item_data.next_action) {
            // capture lender copy for hold
            case 'ill-home-capture' :
                item.needs_capture = true;
                break; 
            // receive item at borrower
            case 'ill-foreign-receive':
            // receive lender copy back home
            case 'transit-home-receive':
            // transit item for cancelled hold back home (or next hold)
            case 'transit-foreign-return':
                item.needs_receive = true;
                break; 
            // complete borrower circ, transit item back home
            case 'ill-foreign-checkin':
                item.needs_checkin = true;
                break;
            // check out item to borrowing patron
            case 'ill-foreign-checkout':
                item.needs_checkout = true;
                break;
        }

        item.status_str = copy.status().name();
        item.copy_status_warning = (copy.status().holdable() == 'f');

        if (transit) {
            item.transit = transit;
            item.transit_source = transit.source().shortname();
            item.transit_dest = transit.dest().shortname();
            item.transit_routing_code = transit.dest().routing_code();
            item.transit_time = transit.source_send_time();
            item.transit_recv_time = transit.dest_recv_time();
            item.open_transit = !Boolean(transit.dest_recv_time());
        }

        if (circ) {
            item.circ = circ;
            item.due_date = circ.due_date();
            item.circ_circ_lib = egOrg.get(circ.circ_lib()).shortname();
            item.circ_xact_start = circ.xact_start();
            item.circ_stop_fines = circ.stop_fines();
            // FF patrons will all have cards, but some test logins may not
            item.patron_id = circ.usr().id();
            item.patron_card = circ.usr().card() ? 
                circ.usr().card().barcode() : circ.usr().usrname();
            item.patron_name = circ.usr().first_given_name() + ' ' + circ.usr().family_name() // i18n
            item.can_mark_lost = (item.circ && item.copy.status().id() == 1); // checked out
        }

        if (hold) {
            item.hold = hold;
            item.hold_id = hold.id();
            item.patron_id = hold.usr().id();
            item.patron_card = hold.usr().card() ? 
                hold.usr().card().barcode() : hold.usr().usrname();
            item.patron_name = hold.usr().first_given_name() + ' ' + hold.usr().family_name() // i18n
            item.hold_request_lib = egOrg.get(hold.request_lib()).shortname();
            item.hold_pickup_lib = egOrg.get(hold.pickup_lib()).shortname();
            item.hold_request_time = hold.request_time();
            item.hold_capture_time = hold.capture_time();
            item.hold_shelf_time = hold.shelf_time();
            item.hold_shelf_expire_time = hold.shelf_expire_time();
            if (hold.cancel_time()) {
                item.hold_cancel_time = hold.cancel_time();
                if (hold.cancel_cause()) {
                    item.hold_cancel_cause = hold.cancel_cause().label();
                }
            }
        }
    }

    $scope.draw = function(barcode) {
        if ($scope.illRouteParams.barcode != barcode) {
            // keep the scan box and URL in sync
            $location.path('/fulfillment/status/' + encodeURIComponent(barcode));
        } else {
            var owner_context = $scope.illRouteParams.owner || orgSelector.current().id();
            $scope.itemList.items = [];
            $scope.item = {index : 0, barcode : barcode};
            $scope.selectMe = true;
            $scope.itemList.items.push($scope.item);
            egNet.request(
                'open-ils.circ',
                'open-ils.circ.item.transaction.disposition',
                egAuth.token(), owner_context, barcode
            ).then(function(items) {
                if (items[0]) {
                    flattenItem($scope.item, items[0]);
                } else {
                   $scope.itemList.items.pop().not_found = true;
                }
            });
        }
    }

    // item status actions all call the parent scope's action
    // handlers unadorned then reload the route.
    // TODO: set selected == item; no more need for custom action handers??
    angular.forEach(['checkin', 'checkout', 'block_one', 'block_all', 'unblock_all', 'popup_abort_block_ill', 
            'cancel', 'abort_transit', 'retarget', 'mark_lost', 'popup_block_ill'],
        function(action) {
            $scope[action] = function() {
                $scope.actions[action]($scope.item, $scope)
                .then(function(resp) {$route.reload()});
            };
        }
    );

    // barcode passed via URL
    if ($scope.illRouteParams.barcode) {
        $scope.barcode = $scope.illRouteParams.barcode;
        $scope.draw($scope.illRouteParams.barcode);
    }
}])

.controller('SingleScanCtrl',
        ['$scope','$q','$route','$location','egPCRUD','orgSelector','egNet','egAuth','egOrg',
function ($scope,  $q,  $route,  $location,  egPCRUD,  orgSelector,  egNet,  egAuth,  egOrg) {
    $scope.focusBC = true;
    $scope.focusAction = false;

    // TODO: can we trim this down?
    function flattenItem(item, item_data) {
        var copy = item_data.copy;
        var transit = item_data.transit;
        var circ = item_data.circ;
        var hold = item_data.hold;
        if (hold) {
            if (!transit && hold.transit()) {
                transit = item_data.hold.transit();
            }
        } else if (transit && transit.hold_transit_copy()) {
            hold = transit.hold_transit_copy().hold();
        }

        item.copy = item_data.copy;
        item.copy_id = item_data.copy.id();
        item.item_barcode = copy.barcode();
        item.item_barcode_enc = encodeURIComponent(copy.barcode());
        var copybar = item.copy_barcode_enc;
        item.circ_lib = egOrg.get(copy.circ_lib()).shortname();
        item.circ_lib_id = egOrg.get(copy.circ_lib()).id();
        item.title = copy.call_number().record().simple_record().title();
        item.author = copy.call_number().record().simple_record().author();
        item.call_number = copy.call_number().label();
        item.bib_id = copy.call_number().record().id();
        item.remote_bib_id = copy.call_number().record().remote_id();
        item.next_action = item_data.next_action;
        item.can_cancel_hold = (item_data.can_cancel_hold == 1);
        item.can_retarget_hold = (item_data.can_retarget_hold == 1);

        switch(item_data.next_action) {
            // capture lender copy for hold
            case 'ill-home-capture' :
                item.next_action_label = 'Capture Outgoing ILL';
                item.next_action_function = 'checkin';
                item.needs_capture = true;
                break; 
            // receive item at borrower
            case 'ill-foreign-receive':
                item.needs_receive = true;
                item.next_action_function = 'checkin';
                item.next_action_label = 'Capture Incoming ILL';
                break;
            // receive lender copy back home
            case 'transit-home-receive':
                item.needs_receive = true;
                item.next_action_function = 'checkin';
                item.next_action_label = 'Receive Returning ILL';
                break;
            // transit item for cancelled hold back home (or next hold)
            case 'transit-foreign-return':
                item.needs_receive = true;
                item.next_action_function = 'checkin';
                item.next_action_label = 'Send Returning ILL';
                break;
            // complete borrower circ, transit item back home
            case 'ill-foreign-checkin':
                item.next_action_label = 'Checkin ILL';
                item.next_action_function = 'checkin';
                item.needs_checkin = true;
                break;
            // check out item to borrowing patron
            case 'ill-foreign-checkout':
                item.next_action_function = 'checkout';
                item.next_action_label = 'Checkout ILL';
                item.needs_checkout = true;
                break;
        }

        item.status_str = copy.status().name();
        item.copy_status_warning = (copy.status().holdable() == 'f');

        if (transit) {
            item.transit = transit;
            item.transit_source = transit.source().shortname();
            item.transit_dest = transit.dest().shortname();
            item.transit_routing_code = transit.dest().routing_code();
            item.transit_time = transit.source_send_time();
            item.transit_recv_time = transit.dest_recv_time();
            item.open_transit = !Boolean(transit.dest_recv_time());
        }

        if (circ) {
            item.circ = circ;
            item.due_date = circ.due_date();
            item.circ_circ_lib = egOrg.get(circ.circ_lib()).shortname();
            item.circ_xact_start = circ.xact_start();
            item.circ_stop_fines = circ.stop_fines();
            // FF patrons will all have cards, but some test logins may not
            item.patron_id = circ.usr().id();
            item.patron_card = circ.usr().card() ? 
                circ.usr().card().barcode() : circ.usr().usrname();
            item.patron_name = circ.usr().first_given_name() + ' ' + circ.usr().family_name() // i18n
            item.can_mark_lost = (item.circ && item.copy.status().id() == 1); // checked out
        }

        if (hold) {
            item.hold = hold;
            item.hold_id = hold.id();
            item.patron_id = hold.usr().id();
            item.patron_card = hold.usr().card() ? 
                hold.usr().card().barcode() : hold.usr().usrname();
            item.patron_name = hold.usr().first_given_name() + ' ' + hold.usr().family_name() // i18n
            item.hold_request_lib = egOrg.get(hold.request_lib()).shortname();
            item.hold_pickup_lib = egOrg.get(hold.pickup_lib()).shortname();
            item.hold_request_time = hold.request_time();
            item.hold_capture_time = hold.capture_time();
            item.hold_shelf_time = hold.shelf_time();
            item.hold_shelf_expire_time = hold.shelf_expire_time();
            if (hold.cancel_time()) {
                item.hold_cancel_time = hold.cancel_time();
                if (hold.cancel_cause()) {
                    item.hold_cancel_cause = hold.cancel_cause().label();
                }
            }
        }
    }

    $scope.draw = function(barcode) {
        if ($scope.illRouteParams.barcode != barcode) {
            // keep the scan box and URL in sync
            $location.path('/fulfillment/singlescan/' + encodeURIComponent(barcode));
        } else {
            var owner_context = $scope.illRouteParams.owner || orgSelector.current().id();
            $scope.itemList.items = [];
            $scope.item = {index : 0, barcode : barcode};
            $scope.selectMe = true;
            $scope.itemList.items.push($scope.item);
            egNet.request(
                'open-ils.circ',
                'open-ils.circ.item.transaction.disposition',
                egAuth.token(), owner_context, barcode
            ).then(function(items) {
                if (items.length > 1) {
                    $scope.itemList.items.pop(); // get rid of the list singleton
                    $scope.item = null; // also the global singleton
                    angular.forEach(items, function(i,ind) {
                        $scope.itemList.items.push(
                            flattenItem({ index: ind, barcode : barcode }, i)
                        );
                    });
                } else if (items[0]) {
                    flattenItem($scope.item, items[0]);
                    $scope.focusBC = false;
                    $scope.focusAction = true;
                } else {
                    $scope.itemList.items.pop().not_found = true;
                }
            });
        }
    }

    $scope.do = {};

    // item status actions all call the parent scope's action
    // handlers unadorned then reload the route.
    // TODO: set selected == item; no more need for custom action handers??
    angular.forEach(['checkin', 'checkout', 'block_one', 'block_all', 'popup_abort_block_ill', 
            'cancel', 'abort_transit', 'retarget', 'mark_lost', 'popup_block_ill'],
        function(action) {
            $scope[action] = function() {
                $scope.actions[action]($scope.item, $scope)
                .then(function(resp) {$route.reload()});
            };
            $scope.do[action] = function(i) {
                $scope.actions[action](i)
                .then(function(resp) {$route.reload()});
            };
        }
    );

    // barcode passed via URL
    if ($scope.illRouteParams.barcode) {
        $scope.barcode = $scope.illRouteParams.barcode;
        $scope.draw($scope.illRouteParams.barcode);
    }
}])

// http://stackoverflow.com/questions/17629126/how-to-upload-a-file-using-angularjs-like-the-traditional-way
.factory('formDataObject', function() {
    return function(data) {
        var fd = new FormData();
        angular.forEach(data, function(value, key) {
            fd.append(key, value);
        });
        return fd;
    };
})

.controller('RecordsCtrl', 
       ['$scope','$q','$http','orgSelector','formDataObject','egAuth',
function($scope,  $q,  $http,  orgSelector,  formDataObject,  egAuth) {

    $scope.uploadRecords = function(file) {
        $scope.in_flight = true;
        var deferred = $q.defer();

        var args = {
            ses : egAuth.token(),
            //  ng-model doesn't support type=file; 
            //  TODO: create a service for file uploads
            //  http://stackoverflow.com/questions/17063000/ng-model-for-input-type-file
            loadFile : $('#record-file')[0].files[0],
            uploadLocation : orgSelector.current().id()
        }

        if (!args.loadFile) return;

        console.log('uploading file ' + args.loadFile);

        $http({
            method: 'POST',
            url: '/ff/fast_import',
            data: args,
            transformRequest: formDataObject,
            headers: {'Content-Type': 'multipart/form-data'}
        })
        .success(function(data, status, headers, config) {
            $scope.in_flight = false;
            $scope.uploadComplete = true;
            deferred.resolve(data);
        })
        .error(function(data, status, headers, config){
            console.warn("upload failed: " + status);
            $scope.in_flight = false;
            $scope.uploadFailed = true;
            deferred.reject(status);
        });

        return deferred.promise;
    };
}])

