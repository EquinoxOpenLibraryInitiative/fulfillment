/**
 * Core Service - egEnv
 *
 * Manages startup data loading.  All registered loaders run 
 * simultaneously.  When all promises are resolved, the promise
 * returned by egEnv.load() is resolved.
 *
 * Generic and class-based loaders are supported.  
 *
 * To load a registred class, push the class hint onto 
 * egEnv.loadClasses.  
 *
 * // will cause all 'pgt' objects to be fetched
 * egEnv.loadClasses.push('pgt');
 *
 * To register a new class loader,attach a loader function to 
 * egEnv.classLoaders, keyed on the class hint, which returns a promise.
 *
 * egEnv.classLoaders.ccs = function() { 
 *    // loads copy status objects, returns promise
 * };
 *
 * Generic loaders go onto the egEnv.loaders array.  Each should
 * return a promise.
 *
 * egEnv.loaders.push(function() {
 *    return egNet.request(...)
 *    .then(function(stuff) { console.log('stuff!') 
 * });
 */

angular.module('egCoreMod')

// env fetcher
.factory('egEnv', 
       ['$q','egAuth','egPCRUD','egIDL',
function($q,  egAuth,  egPCRUD,  egIDL) { 

    var service = {
        // collection of custom loader functions
        loaders : []
    };

    /* returns a promise, loads all of the specified classes */
    service.load = function() {
        // always assume the user is logged in
        if (!egAuth.user()) return $q.when();

        var allPromises = [];
        var classes = this.loadClasses;
        console.debug('egEnv loading classes => ' + classes);

        angular.forEach(classes, function(cls) {
            allPromises.push(service.classLoaders[cls]());
        });
        angular.forEach(this.loaders, function(loader) {
            allPromises.push(loader());
        });

        return $q.all(allPromises).then(
            function() { console.debug('egEnv load complete') });
    };

    /** given a tree-shaped collection, captures the tree and
     *  flattens the tree for absorption.
     */
    service.absorbTree = function(tree, class_) {
        var list = [];
        function squash(node) {
            list.push(node);
            angular.forEach(node.children(), squash);
        }
        squash(tree);
        var blob = service.absorbList(list, class_);
        blob.tree = tree;
    };

    /** caches the object list both as the list and an id => object map */
    service.absorbList = function(list, class_) {
        var blob = {list : list, map : {}};
        var pkey = egIDL.classes[class_].pkey;
        angular.forEach(list, function(item) {blob.map[item[pkey]()] = item});
        service[class_] = blob;
        return blob;
    };

    /* 
     * list of classes to load on every page, regardless of whether
     * a page-specific list is provided.
     */
    service.loadClasses = ['aou', 'aws'];

    /*
     * Default class loaders.  Only add classes directly to this file
     * that are loaded practically always.  All other app-specific
     * classes should be registerd from within the app.
     */
    service.classLoaders = {
        aou : function() {
            return egPCRUD.search('aou', {parent_ou : null}, 
                {flesh : -1, flesh_fields : {aou : ['children', 'ou_type']}}
            ).then(
                function(tree) {service.absorbTree(tree, 'aou')}
            );
        },
        aws : function() {
            // by default, load only the workstation for the authenticated 
            // user.  to load all workstations, override this loader.
            // TODO: auth.session.retrieve should be capable of returning
            // the session with the workstation fleshed.
            if (!egAuth.user().wsid()) { 
                // nothing to fetch.  
                return $q.when();
            }
            return egPCRUD.retrieve('aws', egAuth.user().wsid())
            .then(function(ws) {service.absorbList([ws], 'aws')});
        }
    };

    return service;
}]);



