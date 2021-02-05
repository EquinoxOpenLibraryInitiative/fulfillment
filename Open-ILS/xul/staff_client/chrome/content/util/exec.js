dump('entering util/exec.js\n');

if (typeof util == 'undefined') var util = {};
util.exec = function(chunk_size) {
    var obj = this;

    this.chunk_size = chunk_size || 1;
    obj.clear_timer = function() {
        try {
            if (typeof obj.debug != 'undefined' && obj.debug) { dump('EXEC: Clearing interval with id = ' + obj._intervalId + '\n'); }
            window.clearInterval(obj._intervalId);
        } catch(E) {
            alert('Error in clear_timer: ' + E);
        }
    }

    return this;
};

util.exec.prototype = {
    // This will create a timer that polls the specified array and shifts off functions to execute
    'timer' : function(funcs,interval) {
        var obj = this;

        obj.clear_timer();
        var intervalId = window.setInterval(
            function() {
                if (typeof obj.debug != 'undefined' && obj.debug) { dump('EXEC: ' + location.pathname + ': Running interval with id = ' + intervalId + '\n'); }
                var i = obj.chunk_size;
                while (funcs.length > 0 && i > 0) {
                    funcs.shift()(); i--;
                }
            },
            interval
        );
        obj._intervalId  = intervalId;
        window.addEventListener('unload',obj.clear_timer,false); 
        return intervalId;
    },
    'clear_timer' : function() {
        var obj = this;
        if (obj._intervalId) {
            obj.clear_timer();
            window.removeEventListener('unload',obj.clear_timer,false);
        }
    },
    // This executes a series of functions, but tries to give other events/functions a chance to
    // execute between each one.
    'chain' : function () {
        var args = [];
        var obj = this;
        for (var i = 0; i < arguments.length; i++) {
            var arg = arguments[i];
            switch(arg.constructor.name) {
                case 'Function' :
                    args.push( arg );
                break;
                case 'Array' :
                    for (var j = 0; j < arg.length; j++) {
                        if (typeof arg[j] == 'function') args.push( arg[j] );
                    }
                break;
                case 'Object' :
                    for (var j in arg) {
                        if (typeof arg[j] == 'function') args.push( arg[j] );
                    }
                break;
            }
        }
        if (args.length > 0) setTimeout(
            function() {
                try {
                    for (var i = 0; (i < args.length && i < obj.chunk_size) ; i++) {
                        try {
                            if (typeof args[i] == 'function') {
                                dump('EXEC: executing queued function.   intervalId = ' + obj._intervalId + '\n');
                                if (obj.debug) {
                                    dump('EXEC: function = ' + args[i] + '\n');
                                }
                                args[i]();
                            } else {
                                alert('FIXME -- typeof args['+i+'] == ' + typeof args[i]);
                            }
                        } catch(E) {
                            dump('EXEC: util.exec.chain error: ' + js2JSON(E) + '\n');
                            var keep_going = false;
                            if (typeof obj.on_error == 'function') {
                                keep_going = obj.on_error(E);
                            }
                            if (keep_going) {
                                if (typeof obj.debug != 'undefined' && obj.debug) { dump('EXEC: chain not broken\n'); }
                                try {
                                    if (args.length > 1 ) obj.chain( args.slice(1) );

                                } catch(E) {
                                    if (typeof obj.debug != 'undefined' && obj.debug) { dump('EXEC: another error: ' + js2JSON(E) + '\n'); }
                                }
                            } else {
                                if (typeof obj.debug != 'undefined' && obj.debug) { dump('EXEC: chain broken\n'); }
                                return;
                            }
                        }
                    }
                    if (args.length > obj.chunk_size ) obj.chain( args.slice(obj.chunk_size) );
                } catch(E) {
                    alert(E);
                }
            }, 0
        );
    }
}

dump('exiting util/exec.js\n');
