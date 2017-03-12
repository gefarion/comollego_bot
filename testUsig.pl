use Test::More;
use strict;

use Data::Dumper;
use Usig;

sub PKG {'Usig'}

require_ok(PKG);

my $usig = PKG->new();

subtest 'normalizar direccion' => sub {

	my $direccion = 'Sarmiento 1000';
	is(scalar @{$usig->normalizar_direccion($direccion, max_resultados => 3)}, 2);
	is(scalar @{$usig->normalizar_direccion($direccion, max_resultados => 5)}, 2);

	my $direccion_normalizada = $usig->normalizar_direccion($direccion)->[0];
	is($direccion_normalizada->{altura}, 1000);
	is($direccion_normalizada->{nombre_partido}, 'CABA');
	is($direccion_normalizada->{nombre_calle}, 'FRAGATA PRES. SARMIENTO');
	is($direccion_normalizada->{tipo}, 'calle_altura');
};

subtest 'normalizar direccion con cruce' => sub {

	my $direccion_normalizada = $usig->normalizar_direccion('Sarmiento y Libertad')->[0];
	is($direccion_normalizada->{nombre_calle}, 'SARMIENTO');
	is($direccion_normalizada->{nombre_calle_cruce}, 'LIBERTAD');
	is($direccion_normalizada->{tipo}, 'calle_y_calle');
	ok(!$direccion_normalizada->{altura});
};

subtest 'obtener coordenadas' => sub {

	my $direccion = $usig->normalizar_direccion('Sarmiento 1000')->[0];
	my $coordenadas = $usig->obtener_coordenadas($direccion);
	ok($coordenadas->{x} > 0);
	ok($coordenadas->{y} > 0);
};

subtest 'obtener coordenadas cruce' => sub {

	my $direccion = $usig->normalizar_direccion('Sarmiento y Libertad')->[0];
	my $coordenadas = $usig->obtener_coordenadas($direccion);
	ok($coordenadas->{x} > 0);
	ok($coordenadas->{y} > 0);
};

subtest 'obtener recorridos' => sub {

	my $origen = $usig->normalizar_direccion('Florida 100')->[0];
	my $destino = $usig->normalizar_direccion('Dean funes 1400')->[0];

	my $recorridos = $usig->obtener_recorridos($origen, $destino, max_resultados => 3);
	is(scalar @$recorridos, 3);
	foreach my $recorrido (@$recorridos) {
		ok(@{ $recorrido->{plan} } > 0);
		ok($recorrido->{tiempo} > 0);
		ok($recorrido->{servicios});
		foreach my $paso (@{ $recorrido->{plan} }) {
			ok($paso);
		}
	}
};


done_testing();
