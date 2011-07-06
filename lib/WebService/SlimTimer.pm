use strict;
use warnings;

package WebService::SlimTimer;

# ABSTRACT: Provides interface to SlimTimer web service.


use Moose;
use MooseX::Method::Signatures;
use Moose::Util::TypeConstraints;
use MooseX::Types::Moose qw(Int Str);

use LWP::UserAgent;
use YAML::XS;

use debug;

use WebService::SlimTimer::Task;
use WebService::SlimTimer::TimeEntry;
use WebService::SlimTimer::Types qw(TimeStamp OptionalTimeStamp);

has api_key => ( is => 'ro', isa => Str, required => 1 );

has user_id => ( is => 'ro', isa => Int, writer => '_set_user_id' );
has access_token => ( is => 'ro', isa => Str, writer => '_set_access_token',
        predicate => 'is_logged_in'
    );

has _user_agent => ( is => 'ro', builder => '_create_ua', lazy => 1 );

# Return a string representation of a TimeStamp.
method _format_time(TimeStamp $timestamp)
{
    use DateTime::Format::RFC3339;
    return DateTime::Format::RFC3339->format_datetime($timestamp)
}

# Create the LWP object that we use. This is currently trivial but provides a
# central point for customizing its creation later.
method _create_ua()
{
    my $ua = LWP::UserAgent->new;
    return $ua;
}

# Common part of _request() and _post(): submit the request and check that it
# didn't fail.
method _submit($req, Str $error)
{
    my $res = $self->_user_agent->request($req);

    debug::log("*** Received " . $res->content) if DEBUG;

    if ( !$res->is_success ) {
        die "$error: " . $res->status_line
    }

    return Load($res->content)
}

# A helper method for creating and submitting an HTTP request without
# any body parameters, e.g. a GET or DELETE.
method _request(Str $method, Str $url, Str :$error!, HashRef :$params)
{
    my $uri = URI->new($url);
    $uri->query_form(
            api_key => $self->api_key,
            access_token => $self->access_token,
            %$params
          );
    my $req = HTTP::Request->new($method, $uri);

    debug::log("*** About to request " . $req->as_string) if DEBUG;

    $req->header(Accept => 'application/x-yaml');

    return $self->_submit($req, $error)
}

# Another helper for POST and PUT requests.
method _post(Str $method, Str $url, HashRef $params, Str :$error!)
{
    my $req = HTTP::Request->new($method, $url);

    $params->{'api_key'} = $self->api_key;

    # POST request is used to log in so we can be called before we have the
    # access token and need to check for this explicitly.
    if ( $self->is_logged_in ) {
        $params->{'access_token'} = $self->access_token;
    }

    $req->content(Dump($params));

    debug::log("*** About to post " . $req->as_string) if DEBUG;

    $req->header(Accept => 'application/x-yaml');
    $req->content_type('application/x-yaml');

    return $self->_submit($req, $error)
}

# Provide a simple single-argument ctor instead of default Moose one taking a
# hash with all attributes values.
around BUILDARGS => sub
{
    die "A single API key argument is required" unless @_ == 3;

    my ($orig, $class, $api_key) = @_;

    $class->$orig(api_key => $api_key)
};


method login(Str $login, Str $password)
{
    my $res = $self->_post(POST => 'http://slimtimer.com/users/token',
            { user => { email => $login, password => $password } },
            error => "Failed to login as \"$login\""
        );

    $self->_set_user_id($res->{user_id});
    $self->_set_access_token($res->{access_token})
}


# Helper for task-related methods: returns either the root tasks URI or the
# URI for the given task if the task id is specified.
method _get_tasks_uri(Int $task_id?)
{
    my $uri = "http://slimtimer.com/users/$self->{user_id}/tasks";
    if ( defined $task_id ) {
        $uri .= "/$task_id"
    }

    return $uri
}


method list_tasks
{
    my $tasks_entries = $self->_request(GET => $self->_get_tasks_uri,
                error => "Failed to get the tasks list"
            );

    # The expected reply structure is an array of hashes corresponding to each
    # task.
    my @tasks;
    for (@$tasks_entries) {
        push @tasks, WebService::SlimTimer::Task->new(%$_);
    }

    return @tasks;
}


method create_task(Str $name)
{
    my $res = $self->_post(POST => $self->_get_tasks_uri,
            { task => { name => $name } },
            error => "Failed to create task \"$name\""
        );

    return WebService::SlimTimer::Task->new($res);
}


method delete_task(Int $task_id)
{
    $self->_request(DELETE => $self->_get_tasks_uri($task_id),
            error => "Failed to delete the task $task_id"
        );
}


method get_task(Int $task_id)
{
    my $res = $self->_request(GET => $self->_get_tasks_uri($task_id),
            error => "Failed to find the task $task_id"
        );

    return WebService::SlimTimer::Task->new($res);
}


method complete_task(Int $task_id, TimeStamp $completed_on)
{
    $self->_post(PUT => $self->_get_tasks_uri($task_id),
            { task => { completed_on => $self->_format_time($completed_on) } },
            error => "Failed to mark the task $task_id as completed"
        );
}



# Helper for time-entry-related methods: returns either the root time entries
# URI or the URI for the given entry if the time entry id is specified.
method _get_entries_uri(Int $entry_id?)
{
    my $uri = "http://slimtimer.com/users/$self->{user_id}/time_entries";
    if ( defined $entry_id ) {
        $uri .= "/$entry_id"
    }

    return $uri
}

# Common part of list_entries() and list_task_entries()
method _list_entries(
    Maybe[Int] $taskId,
    OptionalTimeStamp $start,
    OptionalTimeStamp $end)
{
    my $uri = defined $taskId
                ? $self->_get_tasks_uri($taskId) . "/time_entries"
                : $self->_get_entries_uri;

    my %params;
    $params{'range_start'} = $self->_format_time($start) if defined $start;
    $params{'range_end'} = $self->_format_time($end) if defined $end;

    my $entries = $self->_request(GET => $uri,
                params => \%params,
                error => "Failed to get the entries list"
            );

    my @time_entries;
    for (@$entries) {
        push @time_entries, WebService::SlimTimer::TimeEntry->new($_);
    }

    return @time_entries;
}


method list_entries(TimeStamp :$start, TimeStamp :$end)
{
    return $self->_list_entries(undef, $start, $end);
}


method list_task_entries(Int $taskId, TimeStamp :$start, TimeStamp :$end)
{
    return $self->_list_entries($taskId, $start, $end);
}


method get_entry(Int $entryId)
{
    my $res = $self->_request(GET => $self->_get_entries_uri($entryId),
                error => "Failed to get the entry $entryId"
            );

    return WebService::SlimTimer::TimeEntry->new($res);
}


method create_entry(Int $taskId, TimeStamp $start, TimeStamp $end?)
{
    $end = DateTime->now if !defined $end;

    my $res = $self->_post(POST => $self->_get_entries_uri, {
                    time_entry => {
                        task_id => $taskId,
                        start_time => $self->_format_time($start),
                        end_time => $self->_format_time($end),
                        duration_in_seconds => $end->epoch() - $start->epoch(),
                    }
                },
                error => "Failed to create new entry for task $taskId"
            );

    return WebService::SlimTimer::TimeEntry->new($res);
}


method update_entry(Int $entry_id, Int $taskId, TimeStamp $start, TimeStamp $end)
{
    $self->_post(PUT => $self->_get_entries_uri($entry_id), {
                time_entry => {
                    task_id => $taskId,
                    start_time => $self->_format_time($start),
                    end_time => $self->_format_time($end),
                    duration_in_seconds => $end->epoch() - $start->epoch(),
                }
            },
            error => "Failed to update the entry $entry_id"
        );
}


method delete_entry(Int $entry_id)
{
    $self->_request(DELETE => $self->_get_entries_uri($entry_id),
            error => "Failed to delete the entry $entry_id"
        );
}

1;

__END__
=pod

=head1 NAME

WebService::SlimTimer - Provides interface to SlimTimer web service.

=head1 VERSION

version 0.001

=head1 SYNOPSIS

This module provides interface to L<http://www.slimtimer.com/> functionality.

Notice that to use it you must obtain an API key by creating an account at
SlimTimer web site.

=head1 METHODS

=head2 login

Logs in to SlimTimer using the provided login and password.

This method must be called before doing anything else with this object.

=head2 list_tasks

Returns the list of all tasks involving the logged in user, completed or not.

=head2 create_task

Create a new task with the given name.

=head2 delete_task

Delete the task with the given id (presumably previously obtained from
L<list_tasks>).

=head2 get_task

Find the given task by its id.

=head2 complete_task

Mark the task with the given id as being completed.

=head2 list_entries

Return all the time entries.

If the optional C<start> and/or C<end> parameters are specified, returns only
the entries that begin after the start date and/or before the end one.

=head2 list_task_entries

Return all the time entries for the given task.

Just as L<list_entries>, this method accepts optional C<start> and C<end>
parameters to restrict the dates of the entries retrieved.

=head2 get_entry

Find the given time entry by its id.

=head2 create_entry

Create a new time entry.

Notice that the time stamps should normally be in UTC and not local time or
another time zone.

If the C<end> parameter is not specified, it defaults to now.

Returns the entry that was created.

=head2 update_entry

Changes an existing time entry.

=head2 delete_entry

Deletes a time entry.

=head1 SEE ALSO

L<WebService::SlimTimer::Task>, L<WebService::SlimTimer::TimeEntry>

=head1 BUGS

Currently the C<offset> parameter is not used by C<list_tasks> and
C<list_entries> and C<list_task_entries> methods, so they are limited to 50
tasks for the first one and 5000 entries for the latter two and accessing the
subsequent results is impossible.

Access to the comments and tags of the tasks and time entries objects is not
implemented yet.

=head1 AUTHOR

Vadim Zeitlin <vz-cpan@zeitlins.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Vadim Zeitlin.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

