[about]

## Tabletas gráficas

Una tableta gráfica es un dispositivo de entrada con lápiz que informa la posición absoluta, la presión, la inclinación y la rotación.

## MockTab

MockTab es un controlador para macOS de tabletas gráficas Wacom y Xencelabs. Es compatible con tabletas USB y Bluetooth de las familias Wacom Intuos, Cintiq, Bamboo e Intuos Pro — con especial foco en hardware que el controlador oficial de Wacom ya no admite en las versiones modernas de macOS — además de tabletas con lápiz y pen displays de Xencelabs.

[tabletArea]

## Área activa

El área activa es la parte de la superficie de la tableta que se asigna a la pantalla. La entrada del lápiz fuera de este rectángulo no tiene efecto.

**Redimensionar** – Arrastra cualquier tirador de la vista previa para mover o redimensionar el área activa. Mantén pulsada **Shift** al arrastrar una esquina para fijar la proporción de la pantalla. También puedes introducir valores exactos en los campos Width y Height.

**Asignación proporcional** – Mantiene proporcional la relación entre la tableta y la pantalla para que el cursor recorra distancias iguales en horizontal y vertical. Desactívalo si quieres estirar o comprimir el mapeo a propósito.

**Restablecer a área completa** – Restablece el área activa a toda la superficie de la tableta. Esta acción se puede deshacer con ⌘Z.

## Calibración (pen displays)

El botón **Calibrar…** abre una superposición a pantalla completa con cruces para tocar con la punta del lápiz. Este proceso corrige la separación por paralaje entre la punta del lápiz y el cursor en pantalla que introduce el cristal.

Después de calibrar, **Desplazamiento del puntero** permite ajustar cualquier pequeño desplazamiento constante que quede, por ejemplo si la paralaje cambia un poco según el ángulo de visión.

[penFeel]

## Curva de presión

La curva de presión controla cómo se traduce la presión del lápiz en presión de salida. Una curva cóncava (tirada hacia arriba) hace que los trazos suaves se registren con más fuerza; una curva convexa (tirada hacia abajo) exige más presión para conseguir el mismo efecto.

**Preajustes** – Lineal, Suave y Firme. Al elegir un preajuste se establece la curva; al mover un punto de la curva, cambia automáticamente a una forma personalizada.

## Suavizado de presión

Atenúa el ruido de presión en la parte baja del rango del sensor, que de otro modo aparece como un grosor de línea irregular en trazos lentos y suaves. La presión firme no se altera.

## Estabilización

Reduce el temblor del cursor causado por el pulso de la mano. Los valores más altos suavizan más, pero añaden latencia.

## Distancia de doble clic

Este ajuste controla lo cerca que deben estar dos toques para contar como doble clic. Auméntalo si los dobles clics no se registran; bájalo si se producen dobles clics accidentales al dibujar con normalidad. Arrástralo hasta Off para desactivar el ajuste de posición.

## Movimiento

**Invertir dirección de rotación** – Invierte el sentido de giro del lápiz. Actívalo por aplicación para las apps que interpretan la rotación al revés, como Krita.

**Art Pen: intercambiar inclinación con rotación** – Envía la rotación del barril al control Pen Tilt de Photoshop mediante datos de inclinación simulados, a costa de suprimir la inclinación real mientras está activado. Úsalo en Brush Dynamics → Shape Dynamics → Angle → Pen Tilt. Al activarlo aparecen los deslizadores Tilt Offset y Tilt Magnitude para afinar la señal simulada.

**Movimiento relativo del cursor** – Cambia del modo absoluto (cada punto de la tableta corresponde a un punto fijo de la pantalla, como con un lápiz) al modo relativo (el cursor se mueve según la distancia que desplazas el lápiz, como con un ratón).

## Pan View

Define la velocidad a la que se desplaza el contenido mientras mantienes pulsado un botón de Pan View. Para usarlo, asigna la acción Pan View a cualquier botón del lápiz, tecla express o botón del puck en Button Mapping.

## Comportamiento del clic

**Asistencia de levantamiento** – Mantiene el clic del lápiz activo durante un instante después de levantar la punta, si todavía te estás moviendo rápido, para evitar cortes involuntarios del trazo al dibujar deprisa. Arrástralo hasta Off para desactivarlo.

**Umbral de arrastre** – Exige que el lápiz recorra una distancia mínima antes de que un toque pase a ser un arrastre, lo que absorbe el temblor al apoyar la punta y evita que un toque ligero se convierta en un arrastre accidental. Arrástralo hasta Off para desactivarlo.

[buttons]

## Diagrama del lápiz

Pulsa cualquier botón mientras la ventana está abierta para resaltar su posición; así puedes identificar qué botón físico corresponde a cada ranura de asignación. Al hacer clic en una parte del diagrama — la punta, el borrador o un botón lateral — comienza la grabación de una nueva asignación para esa parte.

**Hover drag** – Mantén pulsado Button 1 (el botón lateral inferior) mientras el lápiz flota sobre la superficie para mover el cursor sin tocar con la punta y hacer gestos de arrastre en el aire.

## Tipos de asignación

- **Botones del ratón** – Clic izquierdo, derecho, central o doble clic  
- **Atajos de teclado** – Haz clic en el campo del atajo y pulsa cualquier combinación de teclas  
- **Modificadores mantenidos** – ⌘ ⌥ ⇧ ⌃ se mantienen mientras el botón siga pulsado  
- **Acciones especiales** – Cambiar pantalla, Borrador, selección de modo del Touch Ring  

## Touch Ring y dial

Los anillos, diales y tiras táctiles admiten varios modos. Cada modo aparece como un resumen de una línea; haz clic en una fila del modo — o en su sector del diagrama junto a la lista — para abrir sus ajustes en el mismo sitio. Asigna Touch Ring Mode → **Ciclo** a un botón para ir pasando de un modo a otro, o **Ir al modo** para saltar directamente a un modo concreto.

**Desplazar** – Convierte el anillo o dial en una rueda de desplazamiento. La velocidad es un multiplicador: 1× equivale a una línea por paso.

**Zoom** y **Girar** – Amplían y giran el lienzo, igual que un gesto en el trackpad, en vez de repetir un atajo de teclado. A velocidad máxima, una vuelta del anillo gira el lienzo por completo. La compatibilidad varía según la app.

**Tecla** – Envía un atajo de teclado en cada dirección.

En Zoom y Girar la velocidad va de Desactivado a Máximo en lugar de un número.

## Iluminación

Algunos dispositivos tienen luces configurables. En el hardware con un anillo iluminado alrededor del dial, la configuración de cada modo incluye el color y el brillo que se muestran mientras ese modo está activo. Los pen displays con botones de marco retroiluminados tienen una fila **Retroiluminación de los botones**. El hardware conserva el último color hasta que lo cambies.

## Borrador

La punta del borrador tiene su propia asignación y se configura en la sección del lápiz. Algunas aplicaciones de dibujo cambian automáticamente a la herramienta de borrado cuando reciben eventos de proximidad del borrador.

## Overrides por app

La barra de overrides de la parte superior permite asignar botones distintos a una aplicación concreta. Los overrides se activan automáticamente cuando esa aplicación pasa al primer plano. La configuración global se aplica en todos los demás casos.

[touch]

## Táctil

Las tabletas con superficie táctil capacitiva informan de los contactos de los dedos junto con la entrada del lápiz. MockTab lo mantiene desactivado de forma predeterminada; activa **Habilitar toque con el dedo** para usarlo. La respuesta varía según la app.

**Tocar para hacer clic** – Un toque breve sin movimiento apreciable envía un clic izquierdo.

**Velocidad del cursor** – Ajusta la velocidad del puntero al arrastrar con un solo dedo. Los valores más bajos permiten un control más fino; los más altos cubren más distancia con menos movimiento.

## Gestos

**Desplazamiento con dos dedos** – Desliza dos dedos en una dirección. Las apps suelen tratarlo como desplazamiento de trackpad.

**Pellizcar para hacer zoom** – Separa o junta dos dedos para hacer zoom.

**Girar** – Coloca dos dedos bien separados sobre la tableta y gíralos alrededor de su centro. Desplazar, hacer zoom y girar son lecturas distintas del mismo gesto con dos dedos, así que cada uno se activa o desactiva por separado.

**Invertir dirección** – On: el contenido se desplaza en sentido contrario al movimiento de los dedos, como una rueda de ratón clásica.

**Desplazamiento con inercia** – El desplazamiento con dos dedos continúa brevemente después de levantar los dedos, igual que la inercia de un trackpad. Desactívalo para mejorar la compatibilidad del desplazamiento en algunas apps, como las vistas de Mes y Año de Calendario, a costa de perder la inercia.

## Área táctil

El área táctil funciona de forma independiente al área activa del lápiz. Arrastra los tiradores de la vista previa para recortar la superficie táctil disponible. La entrada de dedos fuera del rectángulo no tiene efecto.

**Restablecer a superficie completa** – Restablece el área táctil a toda la superficie compatible con tacto.

## Limitaciones

MockTab no admite todavía Mission Control, Spaces, Launchpad ni App Exposé desde el tacto.

[display]

## Mapeo de pantalla

El mapeo de pantalla determina qué pantalla trata la tableta como activa.

**Todas las pantallas** – Mayús-clic en cualquier pantalla del diagrama para abarcar todo el escritorio de forma proporcional. Va bien para flujos de trabajo que se mueven entre varios monitores.

**Una sola pantalla** – Haz clic en una pantalla del diagrama para asignar el área activa solo a esa pantalla.

**Cambiar pantalla** – Asigna la acción Cambiar pantalla a una tecla express o a un botón lateral para recorrer las pantallas conectadas sin abrir los ajustes.

[devices]

## Dispositivos conectados

El panel Devices muestra todas las tabletas y herramientas de lápiz que MockTab ha detectado. Cada fila indica el nombre del dispositivo, el tipo de conexión (USB o Bluetooth) y el estado actual.

Al seleccionar una fila de dispositivo, en el panel de detalles de la derecha aparecen los ajustes y herramientas específicos de ese modelo.

Los dispositivos desconectados permanecen en la lista para que sus perfiles sigan disponibles para inspección o ajuste aunque estén desenchufados. Cuando un dispositivo de la lista vuelve a conectarse, MockTab aplica automáticamente su configuración guardada.

## Detección de conflictos

Si otro controlador de tabletas, como el controlador oficial de Wacom, se ejecuta al mismo tiempo, MockTab intenta detectar el conflicto y mostrar una advertencia.

[profiles]

## Perfiles

Un perfil es una instantánea de la configuración de la tableta: área activa, curva de presión, asignaciones de botones y mapeo de pantalla. Al cambiar de perfil, todos esos ajustes se aplican de inmediato.

**Cambio automático** – Cambia automáticamente al perfil correspondiente en cuanto se conecta su tableta.

## Crear y renombrar

Haz clic en **Crear perfil** para guardar la configuración actual como un perfil nuevo. Haz doble clic en el nombre de un perfil para cambiarlo.

## Overrides por app en los perfiles

Cada perfil guarda sus propios overrides por aplicación. Al cambiar de perfil, también cambian los overrides asociados al perfil activo.

## Importar / exportar

Arrastra una tarjeta de perfil al Finder para exportarla como archivo JSON. Arrastra un archivo JSON a la lista de perfiles para importarlo. Los archivos exportados sirven como copia de seguridad y también como forma de compartir perfiles entre equipos.

[scratchpad]

## Scratchpad

El scratchpad es un lienzo de prueba sensible a la presión. Sirve para comprobar rápidamente que el lápiz registra bien la presión, la inclinación y el movimiento.

Tanto la opacidad como el grosor del trazo responden a la presión de la punta. La inclinación afecta al ángulo del trazo cuando el lápiz admite entrada de inclinación. El panel no conserva los trazos; al cerrarlo o limpiarlo, se descarta su contenido.

**Limpiar** – Elimina todos los trazos del lienzo.

[info]

## Entrada en tiempo real

El panel Info muestra en tiempo real los valores del lápiz: posición X/Y, presión, inclinación, rotación, distancia de hover y estado de los botones. Estos valores se actualizan continuamente mientras el lápiz sigue al alcance de la tableta.

Esta vista ayuda a diagnosticar comportamientos inesperados, por ejemplo para confirmar si la presión llega a su valor máximo o si la tableta informa de inclinación.

## Recopilar datos del dispositivo

**Recopilar datos del dispositivo** graba lo que la tableta envía mientras la usas. El resultado es un archivo JSON compacto que puedes adjuntar a una solicitud para añadir o mejorar la compatibilidad con un dispositivo.

[website]

## mocktab.org

El sitio web [mocktab.org](https://mocktab.org) ofrece documentación, notas de versión y la lista completa del hardware compatible.

## GitHub

Los informes de errores y las preguntas van a [github.com/Cyzor/tablet-driver/issues](https://github.com/Cyzor/tablet-driver/issues).

## Agradecimientos

Los datos de dispositivos y la investigación de protocolos de MockTab se apoyan en el trabajo de dos proyectos de código abierto: [OpenTabletDriver](https://opentabletdriver.net/), cuyas configuraciones cubren modelos de muchas marcas, y [Linux Wacom Project](https://linuxwacom.github.io/), fuente de referencia para las dimensiones de dispositivos Wacom a través de su biblioteca libwacom.
