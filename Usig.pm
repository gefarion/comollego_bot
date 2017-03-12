package Usig;
use strict;

use Data::Dumper;
use Mojo::UserAgent;
use Encode qw(encode_utf8);
use utf8;
use Mojo::JSON qw(decode_json encode_json);

my $SERVICIO_SUBTE = 1;
my $SERVICIO_TREN = 2;
my $SERVICIO_COLECTIVO = 3;

my $URL_NORMALIZADOR = "http://servicios.usig.buenosaires.gob.ar/normalizar?";
my $URL_GEOCODER = "http://ws.usig.buenosaires.gob.ar/geocoder/2.2/geocoding/?";
my $URL_RECORRIDOS = "http://recorridos.usig.buenosaires.gob.ar/2.0/consultar_recorridos?";


sub log_error {
	my ($self, $msg) = @_;
	if ($self->{log}) { $self->{log}->error($msg);
	} else { warn $msg; }
}

sub log_info {
	my ($self, $msg) = @_;
	if ($self->{log}) { $self->{log}->info($msg);
	} else { warn $msg; }
}

sub new {
	my ($pkg, $log) = shift;

	return bless { log => $log }, $pkg;
}

sub normalizar_geo {
	my ($self, $lat, $lng, %opts) = @_;

	my $ua = Mojo::UserAgent->new;
	my $url = $URL_NORMALIZADOR . "lat=$lat&lng=$lng";

	if ($opts{callback}) {
		$ua->get($url => sub {
			my ($ua, $tx) = @_;
			return $opts{callback}->($tx->sucess ? $tx->res->json : undef);
		});
	} else {
		my $res = $ua->get($url)->res;
		return $res ? $res->json : undef;
	}
}

sub normalizar_direccion {
	my ($self, $direccion, %opts) = @_;

	$direccion =~ s/\s/%20/g;
	my $ua = Mojo::UserAgent->new;

	my $url = $URL_NORMALIZADOR . "direccion=$direccion";
	$url .= "&maxOptions=" . $opts{max_resultados} if $opts{max_resultados};

	if ($opts{callback}) {
		$ua->get($url => sub {
			my ($ua, $tx) = @_;
			return $opts{callback}->($tx->sucess ? $tx->res->json->{direccionesNormalizadas} : undef);
		});
	} else {
		my $res = $ua->get($url)->res;
		return $res ?  [grep {$_->{nombre_partido} eq 'CABA'} @{$res->json->{direccionesNormalizadas} || []}] : undef;
	}
}

sub obtener_coordenadas {
	my ($self, $direccion, %opts) = @_;

	my $ua = Mojo::UserAgent->new;

	my $url = $URL_GEOCODER;
	if ($direccion->{tipo} eq 'calle_altura') {
		$url .= "cod_calle=$direccion->{cod_calle}&altura=$direccion->{altura}"
	} else {
		$url .= "cod_calle1=$direccion->{cod_calle}&cod_calle2=$direccion->{cod_calle_cruce}"
	}

	if ($opts{callback}) {
		$ua->get($url => sub {
			my ($ua, $tx) = @_;
			if ($tx->sucess) {
				$tx->res->body =~ /^\((.*)\)$/;
				return $opts{callback}->(decode_json($1));
			} else {
				return $opts{callback}->();
			}
		});
	} else {
		my $res = $ua->get($url)->res;
		if ($res) {
			$res->body =~ /^\((.*)\)$/;
			return decode_json($1);
		} else {
			return undef;
		}
	}
}

sub explicar_paso_subte {
	my ($self, $paso) = @_;

	if ($paso->{type} eq 'Board') {
		return [
			sprintf('Caminar hasta la estación <b>%s</b> en <b>%s</b>', $paso->{stop_name}, $paso->{stop_description}),
			sprintf('Tomar el subte <b>%s</b> (en dirección a <b>%s</b>)', $paso->{service}, $paso->{trip_description})
		];
	}
	if ($paso->{type} eq 'SubWayConnection') {
		return sprintf('Bajarse en la estación <b>%s</b> y combinar con el subte <b>%s</b> (en dirección <b>%s</b>) en estación <b>%s</b>',
			$paso->{stop_from}, $paso->{service_to}, $paso->{trip_description}, $self->{stop});
	}
	if ($paso->{type} eq 'Alight') {
		return sprintf('Bajarse en estación <b>%s</b> en <b>%s</b>', $paso->{stop_name}, $paso->{stop_description});
	}

	$self->log_error("ERROR: Tipo paso subte no implementado: $paso->{type}");
	return undef;
}

sub explicar_paso_tren {
	my ($self, $paso) = @_;

	if ($paso->{type} eq 'Board') {
		return [
			sprintf('Caminar hasta la estación <b>%s</b> en <b>%s</b>', $paso->{stop_name}, $paso->{stop_description}),
			sprintf('Tomar el tren <b>%s</b> (en dirección a <b>%s</b>)', $paso->{service}, $paso->{trip_description})
		];
	}
	if ($paso->{type} eq 'Alight') {
		return sprintf('Bajarse en estación <b>%s</b> en <b>%s</b>', $paso->{stop_name}, $paso->{stop_description});
	}

	$self->log_error("ERROR: Tipo paso subte no implementado: $paso->{type}");
	return undef;
}

sub explicar_paso_colectivo {
	my ($self, $paso) = @_;

	if ($paso->{type} eq 'Board') {
		return sprintf('Caminar hasta <b>%s</b> y tomar el colectivo Linea <b>%s</b> <b>%s</b>',
			$paso->{stop_description}, $paso->{service}, $paso->{long_name} ? '(no todos los ramales conducen a destino)': '')
	}

	if ($paso->{type} eq 'Alight') {
		return sprintf('Bajarse del colectivo en <b>%s</b>', $paso->{stop_description});
	}

	$self->log_error("ERROR: Tipo paso colectivo no implementado: $paso->{type}");
	return undef;
}

sub explicar_paso {
	my ($self, $paso) = @_;

	if ($paso->{type} eq 'FinishWalking') {
		return 'Caminar hasta <b>destino</b>';
	}

	if ($paso->{service_type} == $SERVICIO_SUBTE) {
		return $self->explicar_paso_subte($paso);
	}

	if ($paso->{service_type} == $SERVICIO_TREN) {
		return $self->explicar_paso_tren($paso);
	}

	if ($paso->{service_type} == $SERVICIO_COLECTIVO) {
		return $self->explicar_paso_colectivo($paso);
	}

	if ($paso->{service_type}) {
		$self->log_error("ERROR: Tipo de servicio no implementado: $paso->{service_type}");
		return undef;
	} else {
		return "";
	}
}

sub parsear_recorrido {
	my ($self, $recorrido) = @_;

	my @pasos;
	foreach my $paso (@{ $recorrido->{plan} }) {
		my $explicacion = $self->explicar_paso($paso);
		if (ref($explicacion) eq 'ARRAY') {
			push @pasos, @$explicacion;
		} elsif (defined $explicacion) {
			push @pasos, $explicacion if $explicacion ne "";
		} else {
			warn "No se pudo parsear el recorrido";
			return undef;
		}
	}

	return {
		tiempo    => $recorrido->{tiempo},
		servicios => $recorrido->{services},
		plan      => \@pasos,
	};
}

sub obtener_recorridos {
	my ($self, $origen, $destino, %opts) = @_;

	my %params = (
		tipo                        => 'transporte',
		gml                         => 'false',
		precargar                   => 100,
		opciones_caminata           => 800,
		opciones_medios_colectivo   => 'true',
		opciones_medios_subte       => 'true',
		opciones_medios_tren        => 'true',
		opciones_prioridad          => 'avenidas',
		opciones_incluir_autopistas => 'true',
		opciones_cortes             => 'true',
		max_resultados              => 10,
		%opts
	);

	if ($origen->{tipo} eq 'calle_altura') {
		$params{origen_calles} = $origen->{cod_calle};
		$params{origen_calle_altura} = $origen->{altura};
	} else {
		$params{origen_calles} = $origen->{cod_calle};
		$params{origen_calles2} = $origen->{cod_calle_cruce};
	}

	if ($destino->{tipo} eq 'calle_altura') {
		$params{destino_calles} = $destino->{cod_calle};
		$params{destino_calle_altura} = $destino->{altura};
	} else {
		$params{destino_calles} = $destino->{cod_calle};
		$params{destino_calles2} = $destino->{cod_calle_cruce};
	}

	if ($opts{max_resultados}) {
		delete $params{max_resultados};
		$params{max_results} = $opts{max_resultados};
	}

	my $url = $URL_RECORRIDOS;
	while (my ($clave, $valor) = each %params) {
		$url .= "$clave=$valor&";
	}

	my $ua = Mojo::UserAgent->new;
	if ($opts{callback}) {
		$ua->get($url => sub {
			my ($ua, $tx) = @_;
			return $opts{callback}->($tx->sucess
				? [map { $self->parsear_recorrido(decode_json(encode_utf8($_))) } @{ $tx->res->json->{planning} }]
				: undef
			);
		});
	} else {
		my $res = $ua->get($url)->res;
		if ($res) {
			return [map { $self->parsear_recorrido(decode_json(encode_utf8($_))) } @{ $res->json->{planning} }];
		} else {
			return undef;
		}
	}
}

1;
