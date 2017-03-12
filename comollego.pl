#!/usr/bin/perl
use strict;

use WWW::Telegram::BotAPI;
use Data::Dumper;
use Mojo::IOLoop;
use utf8;
use Mojo::Log;
use Env qw(BOT_TOKEN);
use Mojo::JSON qw(to_json);

use Usig;

my $RE_NUEVA_CONSULTA        = qr/^\s*desde\s+(.+)\s+hasta\s+(.+)$/i;
my $RE_NUEVA_CONSULTA_RAPIDA = qr/^\s*hasta\s+(.+)$/i;

my $CONSULTA_TIEMPO_VIDA = 900; # Tiempo de vida de una consulta en segundos

my %CONSULTAS_ACTIVAS;
# Consultas activas de los usuarios, hash por id de usuario
# estado           => seleccionar_origen, seleccionar_destino, seleccionar_recorrido
# opciones_origen  => array de opciones de origen
# opciones_destino => array de opciones de destino
# origen           => direccion origen seleccionada
# destino          => direccion destino seleccionada
# recorridos       => array de recorridos calculados
# ts_creacion      => timestamp de creacion de la consulta

my $LOG = Mojo::Log->new(path => 'comollego.log', level => 'info');

sub log_info { $LOG->info("\[$_[0]->{message}{from}{username}\] " . $_[1]); }
sub log_warn { $LOG->warn("\[$_[0]->{message}{from}{username}\] " . $_[1]); }
sub log_error {
	$LOG->error("\[$_[0]->{message}{from}{username}\] " . $_[1]);
	delete $CONSULTAS_ACTIVAS{$_[0]->{message}{from}{id}};
}

sub main {

	my $last_update = 0;
	my $start_time = time();

	unless($BOT_TOKEN) {
		die "Debe estar definida la variable de entorno BOT_TOKEN";
	}

	my $api = WWW::Telegram::BotAPI->new (
		token => $BOT_TOKEN, 
		async => 1,
	);

	my $usig = Usig->new($LOG);

	Mojo::IOLoop->recurring(0.5 => sub {
		$api->getUpdates({offset => $last_update + 1}, sub {
			my ($ua, $tx) = @_;
			unless ($tx->success) {
				$LOG->error("Error al obtener los updates: " . Dumper($tx->res->body));
				sleep 3;
			}

			limpiar_consultas_antiguas();

			my $res = $tx->res->json;
			return unless $res->{ok};

			foreach my $update (@{$res->{result}}) {
				next unless ($update->{update_id} > $last_update);

				$last_update = $update->{update_id};
				next if $update->{message}{date} < $start_time;

				procesar_mensaje($api, $usig, $update);
			}
		});
	});

	Mojo::IOLoop->start;
}

main();

sub enviar_teclado {
	my ($api, $update, $mensaje, $configuracion, $un_uso) = @_;

	my $reply_keyboard_makeup = {
		keyboard          => $configuracion,
		resize_keyboard   => Mojo::JSON->false,
		one_time_keyboard => $un_uso ? Mojo::JSON->true : Mojo::JSON->false,
	};

	return enviar_mensaje($api, $update, $mensaje,
		reply_markup => to_json($reply_keyboard_makeup));
}

sub enviar_mensaje {
	my ($api, $update, $mensaje, %extra_args) = @_;

	$api->sendMessage({
		chat_id    => $update->{message}{chat}{id},
		text       => $mensaje,
		parse_mode => 'HTML',
		%extra_args,
	}, sub {
		my ($ua, $tx) = @_;
		unless ($tx->success) {
			$LOG->error("Error al enviar mensaje: update=" . to_json($update) . ";=" . $tx->res->body);
		}
	});

	return 1;
}

sub mostrar_ayuda {
	my ($api, $update) = @_;

	log_info($update, "Ayuda servida");

	return enviar_mensaje($api, $update, "<b>== Cómo llego ...? ==</b>
		\nModo de uso:
			- desde <b>DIRECCION</b> hasta <b>DIRECCION</b>
			- hasta <b>DIRECCION</b> (solo mobile)\n
		Ejemplos:
			- desde <b>Sarmiento 1100</b> hasta <b>Cordoba 1500</b>
			- desde <b>Sarmiento y Libertad</b> hasta <b>Gallo 400</b>
			- hasta <b>Cordoba 1500</b>
			- hasta <b>Sarmiento y Libertad</b>
		");
}

sub buscar_consulta_activa {
	my $update = shift;
	return $CONSULTAS_ACTIVAS{$update->{message}{from}{id}};
}

sub generar_nueva_consulta {
	my ($api, $usig, $update) = @_;

	my ($origen, $destino);
	if ($update->{message}{text} =~ $RE_NUEVA_CONSULTA) {
		($origen, $destino) = ($1, $2);
		log_info($update, "Nueva consulta: $origen => $destino");
	} elsif ($update->{message}{text} =~ $RE_NUEVA_CONSULTA_RAPIDA) {
		$destino = $1;
		log_info($update, "Nueva consulta: POSICION ACTUAL => $destino");
	}


	my $opciones_origen;
	if ($origen) {
		$opciones_origen = $usig->normalizar_direccion($origen, max_resultados => 10);
		unless ($opciones_origen && @$opciones_origen) {
			log_warn($update, "No se pudo reconocer la dirección de origen: $origen");
			return enviar_mensaje($api, $update, "No se pudo reconocer la dirección de origen: $origen");
		}
	}

	my $opciones_destino = $usig->normalizar_direccion($destino, max_resultados => 10);
	unless ($opciones_destino && @$opciones_destino) {
		log_warn($update, "No se pudo reconocer la dirección de destino: $destino");
		return enviar_mensaje($api, $update, "No se pudo reconocer la dirección de destino: $destino");
	}

	my $consulta = {
		consulta         => "$origen => $destino",
		opciones_origen  => $opciones_origen,
		opciones_destino => $opciones_destino,
		estado           => 'seleccionar_origen',
		ts_creacion      => time(),
	};
	$CONSULTAS_ACTIVAS{$update->{message}{from}{id}} = $consulta;

	if (!defined $opciones_origen) {
		return enviar_teclado($api, $update, 'Ingrese su posición:', [[{text => "Posición actual", request_location => Mojo::JSON->true}]], 1);
	} elsif (@$opciones_origen == 1) {
		$update->{message}{text} = $opciones_origen->[0]->{direccion};
		return seleccionar_origen($api, $usig, $consulta, $update);
	} else {
		return enviar_teclado($api, $update, 'Seleccione la dirección de origen:',
			[map {[$_->{direccion}]} @$opciones_origen], 1);
	}
}

sub seleccionar_origen {
	my ($api, $usig, $consulta, $update) = @_;

	my $origen;
	if (defined $consulta->{opciones_origen}) {
		# Seleccionó el origen
		($origen) = grep { $update->{message}{text} eq $_->{direccion} } @{ $consulta->{opciones_origen} };
	} else {
		# Seleccionó la posicion
		my $location = $update->{message}{location}; 
		$origen = $usig->normalizar_geo($location->{latitude}, $location->{longitude});
	}

	unless ($origen) {
		log_error($update, "No se pudo recuperar la direccion de origen");
		return enviar_mensaje($api, $update, 'Dirección de origen desconocida');
	}
	$consulta->{origen} = $origen;

	$consulta->{estado} = 'seleccionar_destino';
	delete $consulta->{opciones_origen};

	if (@{ $consulta->{opciones_destino} } == 1) {
		$update->{message}{text} = $consulta->{opciones_destino}->[0]->{direccion};
		return seleccionar_destino($api, $usig, $consulta, $update);
	} else {
		return enviar_teclado($api, $update, 'Seleccione la dirección de destino',
			[map {[$_->{direccion}]} @{$consulta->{opciones_destino}}], 1);
	}
}

sub describir_recorrido { "Servicios: $_[0]->{servicios} ($_[0]->{tiempo}')" }

sub seleccionar_destino {
	my ($api, $usig, $consulta, $update) = @_;

	my ($destino) = grep { $update->{message}{text} eq $_->{direccion} } @{ $consulta->{opciones_destino} };
	unless ($destino) {
		log_error($update, "No se pudo recuperar la direccion de destino: ". $update->{message}{text});
		return enviar_mensaje($api, $update, 'Dirección de destino desconocida');
	}

	$consulta->{destino} = $destino;
	$consulta->{estado} = 'seleccionar_recorrido';
	delete $consulta->{opciones_destino};
	$consulta->{consulta} = "$consulta->{origen}{direccion} => $consulta->{destino}{direccion}";

	my $recorridos = $usig->obtener_recorridos($consulta->{origen}, $destino, max_resultados => 5);
	unless ($recorridos && @$recorridos) {
		log_warn($update, 'No se encontraron recorridos disponibles para la consulta: ' . $consulta->{consulta});
		return enviar_mensaje($api, $update, 'No se encontraron recorridos disponibles');
	}
	$consulta->{opciones_recorrido} = $recorridos;

	return enviar_teclado($api, $update, 'Seleccione un recorrido:',
		[map {[ describir_recorrido($_) ]} @{$consulta->{opciones_recorrido}}], 0);
}

sub seleccionar_recorrido {
	my ($api, $usig, $consulta, $update) = @_;

	my ($recorrido) = grep { $update->{message}{text} eq describir_recorrido($_) } @{ $consulta->{opciones_recorrido} };
	unless ($recorrido) {
		log_error($update, "No se pudo recuperar el recorrido: ". $update->{message}{text});
		return mostrar_ayuda($api, $update);
	}

	log_info($update, "Recorrido servido para la consulta '$consulta->{consulta}': " . describir_recorrido($recorrido));
	return enviar_mensaje($api, $update, describir_recorrido($recorrido) . ":\n- " . join("\n- ", @{ $recorrido->{plan} }));
}

sub limpiar_consultas_antiguas {
	my $ts_actual = time();
	while (my ($usuario_id, $consulta) = each %CONSULTAS_ACTIVAS) {
		if ($ts_actual - $consulta->{ts_creacion} > $CONSULTA_TIEMPO_VIDA) {
			delete $CONSULTAS_ACTIVAS{$usuario_id};
		}
	}
}

sub procesar_mensaje {
	my ($api, $usig, $update) = @_;

	if ($update->{message}{text} =~ $RE_NUEVA_CONSULTA || $update->{message}{text} =~ $RE_NUEVA_CONSULTA_RAPIDA) {
		return generar_nueva_consulta($api, $usig, $update);
	}

	my $consulta = buscar_consulta_activa($update);
	unless ($consulta) {
		return mostrar_ayuda($api, $update);
	}

	if ($consulta->{estado} eq 'seleccionar_origen') {
		return seleccionar_origen($api, $usig, $consulta, $update);
	}

	if ($consulta->{estado} eq 'seleccionar_destino') {
		return seleccionar_destino($api, $usig, $consulta, $update);
	}

	if ($consulta->{estado} eq 'seleccionar_recorrido') {
		return seleccionar_recorrido($api, $usig, $consulta, $update);
	}

	enviar_mensaje($api, $update, 'Opción incorrecta');
	mostrar_ayuda($api, $update);

	return;
}
