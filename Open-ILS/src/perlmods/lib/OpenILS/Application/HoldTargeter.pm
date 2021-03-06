package OpenILS::Application::HoldTargeter;
use strict; 
use warnings;
use OpenILS::Application;
use base qw/OpenILS::Application/;
use OpenILS::Utils::HoldTargeter;
use OpenSRF::Utils::Logger qw(:logger);
use OpenILS::Application::AppUtils;
my $apputils = "OpenILS::Application::AppUtils";

__PACKAGE__->register_method(
    method    => 'hold_targeter',
    api_name  => 'open-ils.hold-targeter.target',
    api_level => 1,
    argc      => 1,
    stream    => 1,
    # Caller is given control over how often to receive responses.
    max_chunk_size => 0,
    signature => {
        desc     => q/Batch or single hold targeter./,
        params   => [
            {   name => 'args',
                type => 'hash',
                desc => q/
API Options:

return_count - Return number of holds processed so far instead 
  of hold targeter result summary objects.

return_throttle - Only reply each time this many holds have been 
  targeted.  This prevents dumping a fast stream of responses
  at the client if the client doesn't need them.

Targeter Options:

hold => <id> OR [<id>, <id>, ...]
 (Re)target one or more specific holds.  Specified as a single hold ID
 or an array ref of hold IDs.

retarget_interval => <interval string>
  Override the 'circ.holds.retarget_interval' global_flag value.

soft_retarget_interval => <interval string>
  Apply soft retarget logic to holds whose prev_check_time sits
  between the retarget_interval and the soft_retarget_interval.

next_check_interval => <interval string>
  Use this interval to determine when the targeter will run next
  instead of relying on the retarget_interval.  This value is used
  to determine if an org unit will be closed during the next iteration
  of the targeter.  Applying a specific interval is useful when
  the retarget_interval is shorter than the time between targeter runs.

newest_first => 1
  Target holds in reverse order of create_time. 

parallel_count => n
  Number of parallel targeters running.  This acts as the indication
  that other targeter instances are running.

parallel_slot => n [starts at 1]
  Sets the parallel targeter instance slot.  Used to determine
  which holds to process to avoid conflicts with other running instances.
/
            }
        ],
        return => {desc => 'See API Options for return types'}
    }
);

sub hold_targeter {
    my ($self, $client, $args) = @_;

    my $targeter = OpenILS::Utils::HoldTargeter->new(%$args);

    $targeter->init;

    my $throttle = $args->{return_throttle} || 1;
    my $count = 0;

    my @hold_ids = $targeter->find_holds_to_target;
    my $total = scalar(@hold_ids);

    $logger->info("targeter processing $total holds");

    for my $hold_id (@hold_ids) {
        $count++;

        # XXX Use the old hold targeter for now.

        # my $single = 
        #     OpenILS::Utils::HoldTargeter::Single->new(parent => $targeter);
        # 
        # # Don't let an explosion on a single hold stop processing
        # eval { $single->target($hold_id) };
        # 
        # if ($@) {
        #     my $msg = "Targeter failed processing hold: $hold_id : $@";
        #     $single->error(1);
        #     $logger->error($msg);
        #     $single->message($msg) unless $single->message;
        # }
        #

        my $result = $apputils->simplereq(
            'open-ils.storage',
            'open-ils.storage.action.hold_request.copy_targeter',
            $args->{retarget_interval},
            $hold_id
        );

        if (($count % $throttle) == 0) { 
            # Time to reply to the caller.  Return either the number
            # processed thus far or the most recent summary object.

            # XXX modified for use with the old hold targeter
            # my $res = $args->{return_count} ? $count : $single->result;

            my $res = $args->{return_count} ? $count : $$result[0];
            $client->respond($res);

            $logger->info("targeted $count of $total holds");
        }
    }

    return undef;
}

1;

