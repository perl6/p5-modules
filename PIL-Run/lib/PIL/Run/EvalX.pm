package PIL::Run::EvalX;
use strict;
use vars qw($VERSION @ISA @EXPORT);
require Exporter;
$VERSION = '0.01';
@ISA = qw(Exporter);
@EXPORT =
    qw(
       pil_from_p6
       p5r_from_p6
       pilc_from_pil
       p5r_from_pilc
       run_p5r
       p6_eval
       p6_eval_file
       );
use PIL::Run::ApiX;
use UNIVERSAL;

sub subnodes_of {
    my($n)=@_;
    if (UNIVERSAL::isa($n,'ARRAY')) {
        @$n;
    } elsif (UNIVERSAL::isa($n,'HASH')) {
        values(%$n);
    } else {
        ();
    }
}

no strict;
package EvalX::BaseClass;
use Scalar::Util qw(blessed);
sub expand {
    my($self,$avoid_recursion)=@_;
    return $avoid_recursion if defined $avoid_recursion;
    my @subnodes = PIL::Run::EvalX::subnodes_of($self);
    my $code = "";
    while (@subnodes) {
        my $n = shift(@subnodes);
        if(blessed($n)) {
            my $flag = rand;
            my $ret = $n->expand($flag);
            if($ret ne $flag) {
                $code .= $ret;
            } else {
                unshift(@subnodes,PIL::Run::EvalX::subnodes_of($n));
            }
        } elsif(ref($n)) {
            unshift(@subnodes,PIL::Run::EvalX::subnodes_of($n));
        }
    }
    $code;
}
package VInt; @ISA = qw(EvalX::BaseClass); sub expand {
    "p6_new('Int','$_[0][0]')";
}
package VNum; @ISA = qw(EvalX::BaseClass); sub expand {
    if ( $_[0][0] eq 'Inf' || $_[0][0] eq 'inf' ) {
        return "p6_new('Num',9E99999999)";
    }
    "p6_new('Num','$_[0][0]')";
}
package VStr; @ISA = qw(EvalX::BaseClass); sub expand {
    my $s = $_[0][0];
    $s =~ s/\\/\\\\/g; $s =~ s/\'/\\\'/g;
    "p6_new('Str','$s')";
}
package PVar; @ISA = qw(EvalX::BaseClass); sub expand {
    use PIL::Run::ApiX;
    my $s = $_[0]{'pVarName'};
    "\n# $s\n".
    p6_var_macro($s,2)
    ."\n";
}
package PApp; @ISA = qw(EvalX::BaseClass); sub expand {
    use PIL::Run::ApiX;
    my($self)=@_;

    return $self->{'pFun'}{'pBody'}->expand() # XXX - bypass PCode - kludge
        if UNIVERSAL::isa($self->{'pFun'},"PCode");

    my $f = $self->{'pFun'}->expand();
    my $invocant = defined $self->{'pInv'} ? $self->{'pInv'}->expand() : undef;
    my @args = map{$_->expand()} @{$self->{'pArgs'}};

    my $f_name = do{my $n=$self;for my $k qw(pFun pLV pVarName){if(exists $n->{$k}){$n=$n->{$k}}else{$n=undef;last}} $n};

    unshift(@args,$invocant) if defined $invocant;

    my($fv) = PIL::Run::EvalX::run_p5r("package ".p6_root.";".$f); # XXX - kludge
    if(defined $fv && ref($fv) =~ /Macro/) { # XXX - kludge
        my $macro_expansion = $fv->do(@args);
        $macro_expansion;
    } elsif(defined $f_name && defined $invocant) {
        # XXX - horrid compensation for mm methods being mere p5 methods.
        my $fn = $f_name; $fn =~ s/^\&//; $fn =~ s/([\\\'])/\\$1/g;
        my $f2 = "do{my \$_f=$f;p6_to_b(\$_f->defined()) ? \$_f : '$fn'}";
        "p6_apply(".join(",",$f2,@args).")";
    } else {
        "p6_apply(".join(",",$f,@args).")";
    }
}
package PAssign; @ISA = qw(EvalX::BaseClass); sub expand {
    'p6_set('.$_[0]{'pLHS'}[0]->expand().','.$_[0]{'pRHS'}->expand().')';
}
package PStmt; @ISA = qw(EvalX::BaseClass); sub expand {
    #$_[0]->SUPER::expand().";\n";
    #"eval(<<'E$n');\n".$_[0]->SUPER::expand().";\nE$n\n";
    my $n = int(rand(10000000));
    "do{my \@_res$n=eval(<<'E$n');warn '#' x 40,\"\\n\",'Fyi: ',\$\@ if \$\@; \@_res$n = \@_res$n;};\n".$_[0]->SUPER::expand().";\nE$n\n";
}
package PThunk; @ISA = qw(EvalX::BaseClass); sub expand {
    my $body = $_[0]->{'pThunk'}{'pLV'}{'pFun'}{'pBody'};
    defined $body ? ' { '.$body->expand().' } ' : $_[0]->SUPER::expand();
}
package PSub; @ISA = qw(EvalX::BaseClass); sub expand {
    use PIL::Run::ApiX;
    my $body = $_[0]{'pSubBody'} eq 'PNil' ? "" : $_[0]{'pSubBody'}->expand();
    my $sub = p6_new_sub_from_pil_macro($_[0]{'pSubName'},
                                        $_[0]{'pSubParams'},
                                        $body,
                                        'macro',
                                        'Sub');
    if($_[0]{'pSubType'} eq 'SubMethod') {
        my $name = $_[0]{'pSubName'};
        my $class = $name;
        $name =~ s/.*:://;
        $class =~ s/::[^:]+$//; $class =~ s/^&//;
        ("(sub{ (::dispatch(::meta(".p6_var_macro(":$class", 2)."),"
         ." 'add_method',"
         ." ('$name' => Perl6::Method->create_instance_method('$class' =>"
         ." sub \{ "
         .$body
         ."})))) })->()"
         .";\n"); # XXX why?
    } else {
        ("BEGIN{"
         ."p6_set(".p6_var_macro($_[0]{'pSubName'},2).','
         .$sub
         .");"
         ."}\n");
    }
}
# package PCode;  also see hack above
package PCode; @ISA = qw(EvalX::BaseClass); sub expand {
    use PIL::Run::ApiX;
    my $body = $_[0]{'pBody'} eq 'PNil' ? "" : $_[0]{'pBody'}->expand();
    my $sub = p6_new_sub_from_pil_macro("<just a block>",
                                        $_[0]{'pParams'},
                                        $body,
                                        'macro',
                                        'Code');
    $sub;
}
package PIL::Environment; @ISA = qw(EvalX::BaseClass); sub expand {
    use PIL::Run::ApiX;
    "package ".&p6_main().";\n".$_[0]->SUPER::expand().";\n";    
}


package PIL::Run::EvalX; # continued.
use strict;

sub get_classes {
    my($node)=@_;
    my @nodes; my %classes;
    push(@nodes,$node);
    while (@nodes) {
        my $n = shift(@nodes);
        my $cls = ref($n) or next;
        $classes{$cls} = 1;
        push(@nodes,subnodes_of($n));
    }
    keys(%classes);
}

my %have_classes = map {($_,1)} qw();
sub define_classes_for {
    my($pilc)=@_;
    my @classes = get_classes($pilc);
    my @classes_needed = grep {!$have_classes{$_}} @classes;
    return if !@classes_needed;
    my $code;
    foreach (@classes_needed) {
        $have_classes{$_} = 1;
        $code .= "package $_; \@ISA = qw(EvalX::BaseClass);\n";
    }
    $code = "no strict;\n".$code;
    #print $code;
    eval($code); die "Eval of class definitions failed. $@" if $@;
}


sub expand {
    my($pilc)=@_;
    define_classes_for($pilc);
    $pilc->expand();
}

#======================================================================

use FindBin;
use File::Spec;
sub path_from_me { File::Spec->catfile($FindBin::Bin, @_) }

my $src_root = path_from_me();
my $pugs = 'pugs'; # path_from_me('..','..','pugs');

sub pil_from_p6 {
    my($p6)=@_;
    $p6 =~ s/^use /require /mg && warn "faking use() with require()\n"; # XXX
    my $fn = "deleteme.p6";
    open(F,">$fn") or die "Couldn't open \"$fn\" for writing: $!\n"; # XXX - kluge
    print F $p6; close F or die "Couldn't close \"$fn\": $!\n";
    my $dir = "-I$src_root/lib6";
    if ( $^O =~ /win/i ) {
        # fixes dir-name-with-spaces in Windows
        $dir = '"' . $dir . '"';
    }
    my $pil = `$pugs $dir -CPerl5 $fn`; #die if $!;
    unlink $fn or die "Couldn't remove \"$fn\": $!\n";
    $pil;
}

sub p5r_from_p6 {
    my($p6)=@_;
    my $pil = pil_from_p6($p6);
    my $pilc = pilc_from_pil($pil);
    my $p5r = p5r_from_pilc($pilc);
    $p5r;
}

sub pilc_from_pil {
    my($pil)=@_;
    my $pilc = eval($pil);
    die "Eval of -CPerl5 code failed. $@" if $@;
    $pilc;
}

sub p5r_from_pilc {
    my($pilc)=@_;
    my $p5r = PIL::Run::EvalX::expand($pilc);
    $p5r;
}


sub with_numbered_lines {
    my($s)=@_;
    my $cnt = 1;
    $s =~ s/^/$cnt++."\t"/mge;
    $s;
}
sub run_p5r {
    my($p5r)=@_;
    my @res = eval($p5r);
    warn "".(caller(0))[3].": $@\n".with_numbered_lines($p5r) if $@;
    @res;
}

sub p6_eval {
    my($p6)=@_;
    my $p5r = p5r_from_p6($p6);
    $p5r = "package ".p6_main."; ".$p5r;
    run_p5r($p5r);
}
sub p6_eval_file {
    my($fn)=@_;
    open IN, $fn or do{ warn "p6_eval_file: $fn: $!\n"; return; };
    my $p6 = do { local $/; <IN> }; close IN;
    eval { p6_eval($p6); };
}

p6_eval('require P5Runtime::PrimP6;');


1;
__END__
