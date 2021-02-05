dump('entering util/functional.js\n');

if (typeof util == 'undefined') var util = {};
util.functional = {};

util.functional.EXPORT_OK    = [ 
    'filter_list', 'filter_object', 'find_list', 'find_object', 'map_list', 'map_flat_list', 
    'map_object', 'map_object_to_list', 'convert_object_list_to_hash', 'find_id_object_in_list', 
    'find_attr_object_in_list', 'walk_tree_preorder', 'unique_list_values',
];
util.functional.EXPORT_TAGS    = { ':all' : util.functional.EXPORT_OK };

util.functional.filter_list = function(list,f) {
    var new_list = [];
    for (var i = 0; i < list.length; i++) {
        var t = f( list[i] );
        if (t) new_list.push( list[i] );
    }
    return new_list;
}

util.functional.filter_object = function(obj,f) {
    var new_obj = {};
    for (var i in obj) {
        var t = f( i, obj[i] );
        if (t) new_obj[i] = obj[i];
    }
    return new_obj;
}

util.functional.find_list = function(list,f) {
    for (var i = 0; i < list.length; i++) {
        var t = f( list[i] );
        if (t) return list[i];
    }
    return null;
}

util.functional.find_object = function(obj,f) {
    for (var i in obj) {
        var t = f( i, obj[i] );
        if (t) return obj[i];
    }
    return null;
}

util.functional.walk_tree_preorder = function(node,children_func,f,parent_node) {
    f(node,parent_node);
    var children = children_func( node );
    if (children) for (var i = 0; i < children.length; i++) {
        util.functional.walk_tree_preorder(
            children[i],
            children_func,
            f,
            node
        );    
    }
}

util.functional.map_list = function(list,f) {
    var new_list = []; var idx = 0;
    for (var i in list) {
        new_list.push( f( list[i], idx++ ) );
    }
    return new_list;
}

util.functional.map_flat_list = function(list,f) {
    var new_list = [];
    for (var i in list) {
        new_list = new_list.concat( f( list[i] ) );
    }
    return new_list;
}

util.functional.map_object = function(obj,f) {
    var new_obj = {};
    for (var i in obj) {
        new_obj[ f( i, obj[i] )[0] ] = f( i, obj[i] )[1];
    }
    return new_obj;
}

util.functional.map_object_to_list = function(obj,f) {
    var new_list = [];
    for (var i in obj) {
        new_list.push( f( obj, i ) );
    }
    return new_list;
}

util.functional.convert_object_list_to_hash = function(list,key_field) {
    var my_hash = new Object();
    if (list) {
        for (var i = 0; i < list.length; i++) {
            if (key_field && typeof list[i][key_field] != 'undefined') {
                if (typeof list[i][key_field] == 'function') {
                    my_hash[ list[i][key_field]() ] = list[i];
                } else {
                    my_hash[ list[i][key_field] ] = list[i];
                }
            } else if (typeof list[i].id == 'function') {
                my_hash[ list[i].id() ] = list[i];
            } else if (typeof list[i].code == 'function') {
                my_hash[ list[i].code() ] = list[i];
            }
        }
    }
    return my_hash;
}

util.functional.find_id_object_in_list = function(list,id) {
    if (list) {
        for (var i = 0; i < list.length; i++ ) {
            try {
                if ( list[i].id() == id ) {
                    return list[i];
                }
            } catch(E) {
                throw(E);
            }
        }
    }
    return null;
}

util.functional.find_attr_object_in_list = function(list,attr,value) {
    if (list) {
        for (var i = 0; i < list.length; i++ ) {
            try {
                var command = 'list[' + i + '].'+attr+'() == ' + value;
                if ( eval(command) ) {
                    return list[i];
                }
            } catch(E) {
                throw(E);
            }
        }
    }
    return null;
}

util.functional.unique_list_values = function(list) {
    var obj = {};
    var finished_list = [];
    for (var i in list) { obj[list[i]] = true; }
    for (var i in obj) { finished_list.push(i); }
    return finished_list;
}

dump('exiting util/functional.js\n');
