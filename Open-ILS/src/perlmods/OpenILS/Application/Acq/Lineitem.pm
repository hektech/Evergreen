package OpenILS::Application::Acq::Picklist;
use base qw/OpenILS::Application/;
use strict; use warnings;

use OpenILS::Event;
use OpenSRF::Utils::Logger qw(:logger);
use OpenILS::Utils::Fieldmapper;
use OpenILS::Utils::CStoreEditor q/:funcs/;
use OpenILS::Const qw/:const/;
use OpenSRF::Utils::SettingsClient;
use OpenILS::Application::AppUtils;
my $U = 'OpenILS::Application::AppUtils';


__PACKAGE__->register_method(
	method => 'create_lineitem',
	api_name	=> 'open-ils.acq.lineitem.create',
	signature => {
        desc => 'Creates a lineitem',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'The lineitem object to create', type => 'object'},
        ],
        return => {desc => 'ID of newly created lineitem on success, Event on error'}
    }
);

sub create_lineitem {
    my($self, $conn, $auth, $li) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;


    if($li->picklist) {
        my $picklist = $e->retrieve_acq_picklist($li->picklist)
            or return $e->die_event;

        if($picklist->owner != $e->requestor->id) {
            return $e->die_event unless 
                $e->allowed('CREATE_PICKLIST', $picklist->org_unit, $picklist);
        }
    
        # indicate the picklist was updated
        $picklist->edit_time('now');
        $e->update_acq_picklist($picklist) or return $e->die_event;
    }

    if($li->purchase_order) {
        my $po = $e->retrieve_acq_purchase_order($li->purchase_order)
            or return $e->die_event;
        return $e->die_event unless 
            $e->allowed('MANAGE_PROVIDER', $po->ordering_agency, $po);
    }

    $li->selector($e->requestor->id);
    $e->create_acq_lineitem($li) or return $e->die_event;

    $e->commit;
    return $li->id;
}

__PACKAGE__->register_method(
	method => 'create_po_assets',
	api_name	=> 'open-ils.acq.purchase_order.assets.create',
	signature => {
        desc => q/Creates assets for each lineitem in the purchase order/,
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'The purchase order id', type => 'number'},
            {desc => q/Options hash./}
        ],
        return => {desc => 'Streams a total versus completed counts object, event on error'}
    }
);

sub create_po_assets {
    my($self, $conn, $auth, $po_id, $options) = @_;
    my $e = new_editor(authtoken=>$auth, xact=>1);
    return $e->die_event unless $e->checkauth;

    my $po = $e->retrieve_acq_purchase_order($po_id) or return $e->event;
    return $e->die_event unless 
        $e->allowed('CREATE_PURCHASE_ORDER', $po->ordering_agency);

    my $li_ids = $e->search_acq_lineitem({purchase_order=>$po_id},{idlist=>1});
    my $total = @$li_ids;
    my $count = 0;

    for my $li_id (@$li_ids) {
        my $resp = create_lineitem_assets_impl($e, $auth, $li_id);
        if($U->event_code($resp)) {
            $e->rollback;
            return $resp;
        }
        $conn->respond({total=>$count, progress=>++$count});
    }

    $po->edit_time('now');
    $e->update_acq_purchase_order($po) or return $e->die_event;
    $e->commit;

    return {complete=>1};
}

__PACKAGE__->register_method(
	method => 'create_lineitem_assets',
	api_name	=> 'open-ils.acq.lineitem.assets.create',
	signature => {
        desc => q/Creates the bibliographic data, volume, and copies associated with a lineitem./,
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'The lineitem id', type => 'number'},
            {desc => q/Options hash./}
        ],
        return => {desc => 'ID of newly created bib record, Event on error'}
    }
);

sub create_lineitem_assets {
    my($self, $conn, $auth, $li_id, $options) = @_;
    my $e = new_editor(authtoken=>$auth, xact=>1);
    return $e->die_event unless $e->checkauth;
    my $resp = create_lineitem_assets_impl($e, $auth, $li_id, $options);
    if($U->event_code($resp)) {
        $e->rollback;
        return $resp;
    }
    $e->commit;
    return $resp;
}

sub create_lineitem_assets_impl {
    my($e, $auth, $li_id, $options) = @_;
    my $li = $e->retrieve_acq_lineitem([
        $li_id,
        {   flesh => 1,
            flesh_fields => {jub => ['purchase_order']}
        }
    ]) or return $e->die_event;

    return OpenILS::Event->new('BAD_PARAMS') # make this perm-based, not owner-based
        unless $li->purchase_order->owner == $e->requestor->id;

    # -----------------------------------------------------------------
    # first, create the bib record if necessary
    # -----------------------------------------------------------------
    unless($li->eg_bib_id) {
        my $record = $U->simplereq(
            'open-ils.cat', 
            'open-ils.cat.biblio.record.xml.import',
            $auth, $li->marc, $li->source_label);

        if($U->event_code($record)) {
            $e->rollback;
            return $record;
        }

        $li->eg_bib_id($record->id);
        $e->update_acq_lineitem($li) or return $e->die_event;
    }

    my $li_details = $e->search_acq_lineitem_detail({lineitem => $li_id}, {idlist=>1});

    # -----------------------------------------------------------------
    # for each lineitem_detail, create the volume if necessary, create 
    # a copy, and link them all together.
    # -----------------------------------------------------------------
    my %volcache;
    for my $li_detail_id (@{$li_details}) {

        my $li_detail = $e->retrieve_acq_lineitem_detail($li_detail_id)
            or return $e->die_event;

        my $volume = $volcache{$li_detail->cn_label};
        unless($volume and $volume->owning_lib == $li_detail->owning_lib) {
            my $vol_id = $U->simplereq(
                'open-ils.cat',
                'open-ils.cat.call_number.find_or_create',
                $auth, $li_detail->cn_label, $li->eg_bib_id, $li_detail->owning_lib);
            $volume = $e->retrieve_asset_call_number($vol_id) or return $e->die_event;
            $volcache{$vol_id} = $volume;
        }

        if($U->event_code($volume)) {
            $e->rollback;
            return $volume;
        }

        my $copy = Fieldmapper::asset::copy->new;
        $copy->isnew(1);
        $copy->loan_duration(2);
        $copy->fine_level(2);
        $copy->status(OILS_COPY_STATUS_ON_ORDER);
        $copy->barcode($li_detail->barcode);
        $copy->location($li_detail->location);
        $copy->call_number($volume->id);
        $copy->circ_lib($volume->owning_lib);

        my $stat = $U->simplereq(
            'open-ils.cat',
            'open-ils.cat.asset.copy.fleshed.batch.update', $auth, [$copy]);

        if($U->event_code($stat)) {
            $e->rollback;
            return $stat;
        }

        my $new_copy = $e->search_asset_copy({deleted=>'f', barcode=>$copy->barcode})->[0]
            or return $e->die_event;

        $li_detail->eg_copy_id($new_copy->id);
        $e->update_acq_lineitem_detail($li_detail) or return $e->die_event;
    }

    return 1;
}



__PACKAGE__->register_method(
	method => 'retrieve_lineitem',
	api_name	=> 'open-ils.acq.lineitem.retrieve',
	signature => {
        desc => 'Retrieves a lineitem',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem ID to retrieve', type => 'number'},
            {options => q/Hash of options, including 
                "flesh_attrs", which fleshes the attributes; 
                "flesh_li_details", which fleshes the order details objects/, type => 'hash'},
        ],
        return => {desc => 'lineitem object on success, Event on error'}
    }
);


sub retrieve_lineitem {
    my($self, $conn, $auth, $li_id, $options) = @_;
    my $e = new_editor(authtoken=>$auth);
    return $e->die_event unless $e->checkauth;
    $options ||= {};

    # XXX finer grained perms...

    my $li;

    if($$options{flesh_attrs}) {
        $li = $e->retrieve_acq_lineitem([
            $li_id, {flesh => 1, flesh_fields => {jub => ['attributes']}}])
            or return $e->event;
    } else {
        $li = $e->retrieve_acq_lineitem($li_id) or return $e->event;
    }

    if($$options{flesh_li_details}) {
        my $ops = {
            flesh => 1,
            flesh_fields => {acqlid => []}
        };
        push(@{$ops->{flesh_fields}->{acqlid}}, 'fund') if $$options{flesh_fund};
        push(@{$ops->{flesh_fields}->{acqlid}}, 'fund_debit') if $$options{flesh_fund_debit};
        my $details = $e->search_acq_lineitem_detail([{lineitem => $li_id}, $ops]);
        $li->lineitem_details($details);
        $li->item_count(scalar(@$details));
    } else {
        my $details = $e->search_acq_lineitem_detail({lineitem => $li_id}, {idlist=>1});
        $li->item_count(scalar(@$details));
    }

    if($li->picklist) {
        my $picklist = $e->retrieve_acq_picklist($li->picklist)
            or return $e->event;
    
        if($picklist->owner != $e->requestor->id) {
            return $e->event unless 
                $e->allowed('VIEW_PICKLIST', undef, $picklist);
        }
    }

    $li->clear_marc if $$options{clear_marc};

    return $li;
}



__PACKAGE__->register_method(
	method => 'delete_lineitem',
	api_name	=> 'open-ils.acq.lineitem.delete',
	signature => {
        desc => 'Deletes a lineitem',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem ID to delete', type => 'number'},
        ],
        return => {desc => '1 on success, Event on error'}
    }
);

sub delete_lineitem {
    my($self, $conn, $auth, $li_id) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;

    my $li = $e->retrieve_acq_lineitem($li_id)
        or return $e->die_event;

    # XXX check state

    if($li->picklist) {
        my $picklist = $e->retrieve_acq_picklist($li->picklist)
            or return $e->die_event;
        return OpenILS::Event->new('BAD_PARAMS') 
            if $picklist->owner != $e->requestor->id;
    } else {
        # check PO perms
    }

    # delete the attached lineitem_details
    my $lid_ids = $e->search_acq_lineitem_detail(
        {lineitem => $li_id}, {idlist=>1});

    for my $lid_id (@$lid_ids) {
        $e->delete_acq_lineitem_detail(
            $e->retrieve_acq_lineitem_detail($lid_id))
            or return $e->die_event;
    }

    $e->delete_acq_lineitem($li) or return $e->die_event;
    $e->commit;
    return 1;
}


__PACKAGE__->register_method(
	method => 'update_lineitem',
	api_name	=> 'open-ils.acq.lineitem.update',
	signature => {
        desc => 'Update a lineitem',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem object update', type => 'object'}
        ],
        return => {desc => '1 on success, Event on error'}
    }
);

sub update_lineitem {
    my($self, $conn, $auth, $li) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;

    my $orig_li = $e->retrieve_acq_lineitem([
        $li->id,
        {   flesh => 1, # grab the lineitem with picklist attached
            flesh_fields => {jub => ['picklist', 'purchase_order']}
        }
    ]) or return $e->die_event;

    # the marc may have been cleared on retrieval...
    $li->marc($e->retrieve_acq_lineitem($li->id)->marc)
        unless $li->marc;

    $e->update_acq_lineitem($li) or return $e->die_event;
    $e->commit;
    return 1;
}

__PACKAGE__->register_method(
	method => 'lineitem_search',
	api_name => 'open-ils.acq.lineitem.search',
    stream => 1,
	signature => {
        desc => 'Searches lineitems',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'Search definition', type => 'object'},
            {desc => 'Optoins hash.  idlist=true', type => 'object'},
            {desc => 'List of lineitems', type => 'object/number'},
        ]
    }
);

sub lineitem_search {
    my($self, $conn, $auth, $search, $options) = @_;
    my $e = new_editor(authtoken=>$auth, xact=>1);
    return $e->event unless $e->checkauth;
    return $e->event unless $e->allowed('CREATE_PICKLIST');
    # XXX needs permissions consideration
    my $lis = $e->search_acq_lineitem($search, {idlist=>1});
    for my $li_id (@$lis) {
        if($$options{idlist}) {
            $conn->respond($li_id);
        } else {
            my $res = retrieve_lineitem($self, $conn, $auth, $li_id, $options);
            $conn->respond($res) unless $U->event_code($res);
        }
    }
    return undef;
}

__PACKAGE__->register_method(
	method => 'create_lineitem_detail',
	api_name	=> 'open-ils.acq.lineitem_detail.create',
	signature => {
        desc => q/Creates a new purchase order line item detail.  
            Additionally creates the associated fund_debit/,
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem_detail to create', type => 'object'},
        ],
        return => {desc => 'The purchase order line item detail id, Event on failure'}
    }
);

sub create_lineitem_detail {
    my($self, $conn, $auth, $li_detail, $options) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;
    $options ||= {};

    my $li = $e->retrieve_acq_lineitem($li_detail->lineitem)
        or return $e->die_event;

    my $evt = update_li_edit_time($e, $li);
    return $evt if $evt;

    # XXX check lineitem provider perms

    if($li_detail->fund) {
        my $fund = $e->retrieve_acq_fund($li_detail->fund) or return $e->die_event;
        return $e->die_event unless 
            $e->allowed('MANAGE_FUND', $fund->org, $fund);
    }

    $e->create_acq_lineitem_detail($li_detail) or return $e->die_event;
    $e->commit;
    return $li_detail->id;
}

__PACKAGE__->register_method(
	method => 'update_lineitem_detail',
	api_name	=> 'open-ils.acq.lineitem_detail.update',
	signature => {
        desc => q/Updates a lineitem detail/,
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem_detail to update', type => 'object'},
        ],
        return => {desc => '1 on success, Event on failure'}
    }
);

sub update_lineitem_detail {
    my($self, $conn, $auth, $li_detail) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;

    if($li_detail->fund) {
        my $fund = $e->retrieve_acq_fund($li_detail->fund) or return $e->die_event;
        return $e->die_event unless 
            $e->allowed('MANAGE_FUND', $fund->org, $fund);
    }

    # XXX check lineitem perms

    my $li = $e->retrieve_acq_lineitem($li_detail->lineitem)
        or return $e->die_event;
    my $evt = update_li_edit_time($e, $li);
    return $evt if $evt;

    $e->update_acq_lineitem_detail($li_detail) or return $e->die_event;
    $e->commit;
    return 1;
}

sub update_li_edit_time {
    my ($e, $li) = @_;
    return OpenILS::Event->new('ACQ_LINEITEM_APPROVED', payload => $li->id)
        if $li->state eq 'approved';
    $li->edit_time('now');
    $e->update_acq_lineitem($li) or return $e->die_event;
    return undef;
}


__PACKAGE__->register_method(
	method => 'delete_lineitem_detail',
	api_name	=> 'open-ils.acq.lineitem_detail.delete',
	signature => {
        desc => q/Deletes a lineitem detail/,
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem_detail ID to delete', type => 'number'},
        ],
        return => {desc => '1 on success, Event on failure'}
    }
);

sub delete_lineitem_detail {
    my($self, $conn, $auth, $li_detail_id) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;
    my $li_detail = $e->retrieve_acq_lineitem_detail([
        $li_detail_id,
        {   flesh => 1,
            flesh_fields => {acqlid => ['lineitem']}
        }
    ]) or return $e->die_event;

    my $li = $li_detail->lineitem;

    my $evt = update_li_edit_time($e, $li);
    return $evt if $evt;

    return OpenILS::Event->new('BAD_PARAMS') unless 
        $li->state =~ /new|approved/;

    # XXX check lineitem perms

    $e->delete_acq_lineitem_detail($li_detail) or return $e->die_event;
    $e->commit;
    return 1;
}


__PACKAGE__->register_method(
	method => 'retrieve_lineitem_detail',
	api_name	=> 'open-ils.acq.lineitem_detail.retrieve',
	signature => {
        desc => q/Updates a lineitem detail/,
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'id of lineitem_detail to retrieve', type => 'number'},
        ],
        return => {desc => 'object on success, Event on failure'}
    }
);
sub retrieve_lineitem_detail {
    my($self, $conn, $auth, $li_detail_id) = @_;
    my $e = new_editor(authtoken=>$auth);
    return $e->event unless $e->checkauth;

    my $li_detail = $e->retrieve_acq_lineitem_detail($li_detail_id)
        or return $e->event;

    if($li_detail->fund) {
        my $fund = $e->retrieve_acq_fund($li_detail->fund) or return $e->event;
        return $e->event unless 
            $e->allowed('MANAGE_FUND', $fund->org, $fund);
    }

    # XXX check lineitem perms
    return $li_detail;
}



__PACKAGE__->register_method(
	method => 'approve_lineitem',
	api_name	=> 'open-ils.acq.lineitem.approve',
	signature => {
        desc => 'Mark a lineitem as approved',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem ID', type => 'number'}
        ],
        return => {desc => '1 on success, Event on error'}
    }
);
sub approve_lineitem {
    my($self, $conn, $auth, $li_id) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;

    # XXX perm checks for each lineitem detail

    my $li = $e->retrieve_acq_lineitem($li_id)
        or return $e->die_event;

    return OpenILS::Event->new('ACQ_LINEITEM_APPROVED', payload => $li_id)
        if $li->state eq 'approved';

    my $details = $e->search_acq_lineitem_detail({lineitem => $li_id});
    return OpenILS::Event->new('ACQ_LINEITEM_NO_COPIES', payload => $li_id)
        unless scalar(@$details) > 0;

    for my $detail (@$details) {
        return OpenILS::Event->new('ACQ_LINEITEM_DETAIL_NO_FUND', payload => $detail->id)
            unless $detail->fund;

        return OpenILS::Event->new('ACQ_LINEITEM_DETAIL_NO_ORG', payload => $detail->id)
            unless $detail->owning_lib;
    }
    
    $li->state('approved');
    $li->edit_time('now');
    $e->update_acq_lineitem($li) or return $e->die_event;

    $e->commit;
    return 1;
}


__PACKAGE__->register_method(
	method => 'receive_lineitem_detail',
	api_name	=> 'open-ils.acq.lineitem_detail.receive',
	signature => {
        desc => 'Mark a lineitem_detail as received',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'lineitem detail ID', type => 'number'}
        ],
        return => {desc => '1 on success, Event on error'}
    }
);
sub receive_lineitem_detail {
    my($self, $conn, $auth, $lid_id) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;
    my $resp = receive_lineitem_detail_impl($e, $lid_id);
    if($resp) {$e->rollback; return $resp;}
    $e->commit;
    return 1;
}

sub receive_lineitem_detail_impl {
    my($e, $lid_id) = @_;

    my $lid = $e->retrieve_acq_lineitem_detail($lid_id)
        or return $e->die_event;

    return OpenILS::Event->new(
        'ACQ_LINEITEM_DETAIL_RECEIVED') if $lid->recv_time;

    $lid->recv_time('now');
    $e->update_acq_lineitem_detail($lid) or return $e->die_event;

    my $copy = $e->retrieve_asset_copy($lid->eg_copy_id)
        or return $e->die_event;

    $copy->status(OILS_COPY_STATUS_IN_PROCESS);
    $copy->edit_date('now');
    $copy->editor($e->requestor->id);
    $e->update_asset_copy($copy) or return $e->die_event;

    # XXX update the fund_debit to encumbrance=false

    my $non_recv = $e->search_acq_lineitem_detail(
        {recv_time => undef, lineitem => $lid->lineitem}, {idlist=>1});

    unless(@$non_recv) {
        # if all of the lineitem details for this lineitem have 
        # been received, mark the lineitem as received
        my $li = $e->retrieve_acq_lineitem($lid->lineitem);
        $li->state('received');
        $li->edit_time('now');
        $e->update_acq_lineitem($li) or return $e->die_event;
    }

    return undef;
}


__PACKAGE__->register_method(
	method => 'set_lineitem_usr_attr',
	api_name	=> 'open-ils.acq.lineitem_usr_attr.set',
	signature => {
        desc => 'Sets a lineitem_usr_attr value',
        params => [
            {desc => 'Authentication token', type => 'string'},
            {desc => 'Lineitem ID', type => 'number'},
            {desc => 'Attr name', type => 'string'},
            {desc => 'Attr value', type => 'string'}
        ],
        return => {desc => '1 on success, Event on error'}
    }
);

sub set_lineitem_usr_attr {
    my($self, $conn, $auth, $li_id, $attr_name, $attr_value) = @_;
    my $e = new_editor(xact=>1, authtoken=>$auth);
    return $e->die_event unless $e->checkauth;

    # XXX perm

    my $attr = $e->search_acq_lineitem_attr({
        lineitem => $li_id, 
        attr_type => 'lineitem_usr_attr_definition',
        attr_name => $attr_name})->[0];

    if($attr) {
        $attr->attr_value($attr_value);
        $e->update_acq_lineitem_attr($attr) or return $e->die_event;
    } else {
        $attr = Fieldmapper::acq::lineitem_attr->new;
        $attr->lineitem($li_id);
        $attr->attr_type('lineitem_usr_attr_definition');
        $attr->attr_name($attr_name);
        $attr->attr_value($attr_value);
        $e->create_acq_lineitem_attr($attr) or return $e->die_event;
    }

    $e->commit;
    return 1;
}



1;
