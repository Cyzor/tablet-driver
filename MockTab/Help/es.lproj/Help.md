[about]

## Tabletas gráficas

Una tableta gráfica es un dispositivo de entrada con lápiz que informa la posición absoluta, la presión, la inclinación y la rotación.

## MockTab

MockTab es un controlador para macOS de tabletas gráficas Wacom y Xencelabs. Es compatible con tabletas USB y Bluetooth de las familias Wacom Intuos, Intuos Pro, Cintiq, Bamboo y Graphire, además de algunos modelos de Xencelabs. Se centra en hardware que el controlador oficial de Wacom ya no admite en las versiones modernas de macOS.

## Desinstalar MockTab

Sal de MockTab y muévelo a la Papelera. Para borrar también sus ajustes, abre cada elemento de abajo en el Finder con **Ir a la carpeta** (⇧⌘G) y muévelo a la Papelera:

- `~/Library/Preferences/com.cyzor.mocktab.plist` – ajustes  
- `~/Library/Application Support/com.cyzor.mocktab` – ajustes anteriores, guardados cada vez que arranca una versión distinta  

[tabletArea]

## Área activa

El área activa es la parte de la superficie de la tableta que se asigna a la pantalla. La entrada del lápiz fuera de este rectángulo no tiene efecto.

**Redimensionar** – Arrastra el área o sus tiradores; cerca de la forma del área de pantalla se ajusta a ella (**⌘** lo evita, **⇧** conserva su forma). Haz clic en la anchura o la altura de abajo para escribir un tamaño exacto.

**Asignación proporcional** – Mantiene iguales los recorridos del cursor en horizontal y vertical. Desactívala para estirar o comprimir el mapeo.

**Restablecer a área completa** – Restaura toda la superficie de la tableta. ⌘Z lo deshace.

## Orientación

Elige la orientación que coincida con la posición actual de la tableta (⌘⌥1 a ⌘⌥4 en el panel Área de tableta). El lápiz, el toque y la inclinación siguen la elección, y el panel Botones dibuja la tableta en consecuencia.

Al girar la tableta, cada asignación pasa a la tecla que ahora ocupa su lugar, en todos los perfiles y overrides por app. Deshacer revierte ambas cosas a la vez.

**Invertir asignaciones** – Haz clic derecho en el dibujo de la tableta del panel Botones para pasar cada asignación a la tecla opuesta sin cambiar la orientación. Elígelo de nuevo para dejarlo como estaba.

## Calibración (pen displays)

**Calibrar…** muestra objetivos a pantalla completa para tocar con la punta del lápiz. Corrige la separación que el cristal introduce entre la punta y el cursor.

**Desplazamiento del puntero** corrige cualquier pequeña separación que quede, por ejemplo una que cambie con el ángulo de visión.

[penFeel]

## Curva de presión

Sube la curva para que los trazos suaves cuenten más, o bájala para necesitar más fuerza. Lineal, Suave y Firme son preajustes.

## Suavizado de presión

Iguala el grosor de línea en trazos lentos y suaves.

## Estabilización

Reduce el temblor del cursor causado por el pulso, a cambio de algo de retraso.

## Distancia de doble clic

Lo cerca que deben caer dos toques para contar como doble clic.

## Movimiento

**Invertir dirección de rotación** – Cambia si girar el cuerpo del lápiz produce un giro en el sentido de las agujas del reloj o en el contrario.

**Movimiento relativo del cursor** – Mueve el cursor como un ratón en lugar de asignar la tableta a la pantalla.

## Desplazar vista

**Velocidad**, **Invertir dirección** y **Desplazamiento con inercia** definen cómo se mueve el contenido mientras mantienes pulsado un botón de Desplazar vista. Asigna Desplazar vista en el panel Botones.

## Comportamiento del clic

**Requerir contacto** – Las acciones marcadas de los botones laterales esperan a que la punta toque. Las acciones de clic sin marcar también funcionan en proximidad, incluso para arrastrar.

**Asistencia de levantamiento** – Evita que los trazos rápidos se corten cuando la punta se levanta un instante.

**Umbral de arrastre** – Evita que un toque se convierta en un pequeño arrastre.

[buttons]

## Diagrama del lápiz

Pulsa cualquier botón mientras la ventana está abierta para resaltar su posición; así puedes identificar qué botón físico corresponde a cada ranura de asignación. Haz clic en la punta, el borrador o un botón lateral del diagrama para grabar una nueva asignación.

## Ratones

Un ratón de Wacom tiene su propio diagrama y sus propias filas de botones. Sus tres primeros botones empiezan como clic izquierdo, derecho y central.

## Diagrama de la tableta

El diagrama muestra la posición de las teclas, anillos y diales de una tableta. Haz clic en un elemento para asignarle una acción.

## Tipos de asignación

- **Botones del ratón** – Clic izquierdo, derecho y central, doble clic y bloqueo de clic, que mantiene pulsado el botón izquierdo hasta la siguiente pulsación  
- **Atajos de teclado** – Haz clic en el campo del atajo y pulsa cualquier combinación de teclas  
- **Modificadores mantenidos** – ⌘ ⌥ ⇧ ⌃ se mantienen mientras el botón siga pulsado  
- **Acciones especiales** – Desplazar vista, Borrador, Barra espaciadora, Escape, F13 a F19, Cambiar pantalla, Distribuir en pantallas, Cambiar modo relativo, Mostrar configuración de MockTab y modos de anillos, diales y franjas  
- **Abrir** – Arrastra una app, un archivo, un enlace o una macro de Keyboard Maestro a la fila de un botón. Un signo de interrogación indica que el destino ya no está. Para escribir o corregir una URL, haz clic derecho en la fila y elige Editar URL  

Para ejecutar un script, un flujo de trabajo de Automator o un atajo, guárdalo como app y arrástrala, o dale una combinación de teclas en Ajustes del Sistema o en Atajos y asigna esa combinación.

## Touch Ring y dial

Los anillos, diales y tiras táctiles tienen cada uno sus propios modos. Haz clic en un modo, o en su sector del diagrama, para cambiar sus ajustes. Para cambiar de modo con un botón, asigna **Ciclo** o **Ir al modo**.

**Desplazar** – Funciona como una rueda de desplazamiento. A 1×, cada paso desplaza una línea.

**Zoom** y **Girar** – Amplían o giran el lienzo, igual que un gesto en el trackpad. La velocidad va de Desactivado a Máximo; en Máximo, una vuelta del anillo gira el lienzo por completo. La compatibilidad varía según la app.

**Tecla** – Envía un atajo de teclado en cada dirección.

## Pantallas de teclas

Una Intuos4 con pantallas de teclas muestra por USB la acción de cada tecla a su lado, y las pantallas se atenúan cuando no hay actividad.

## Iluminación

Los dispositivos con anillo del dial iluminado o botones retroiluminados te permiten ajustar su color y brillo. El hardware mantiene su último color hasta que lo cambies.

## Borrador

El extremo borrador tiene su propia asignación en la sección del lápiz. En un lápiz sin borrador, asigna Borrador a un botón lateral y mantenlo pulsado para borrar con la punta.

## Overrides por app

La barra de overrides de la parte superior permite asignar botones distintos a una aplicación concreta. Los overrides se activan automáticamente cuando esa aplicación pasa al primer plano. La configuración global se aplica en todos los demás casos.

[touch]

## Táctil

Algunas tabletas también detectan los dedos. MockTab mantiene el toque desactivado de forma predeterminada; activa **Habilitar toque con el dedo** para usarlo. La respuesta varía según la app.

**Tocar para hacer clic** – Un toque breve sin movimiento apreciable envía un clic izquierdo.

**Clic derecho con dos dedos** – Un toque breve con dos dedos, separados el ancho de una yema, envía un clic derecho.

**Arrastrar con tres dedos** – Al apoyar tres dedos a la vez, el botón del ratón queda pulsado. Muévelos para arrastrar y levántalos para soltar.

**Velocidad del cursor** – Ajusta la velocidad del puntero al arrastrar con un solo dedo. Los valores más bajos permiten un control más fino; los más altos cubren más distancia con menos movimiento.

## Gestos

**Desplazamiento con dos dedos** – Desliza dos dedos en una dirección. Las apps suelen tratarlo como desplazamiento de trackpad.

**Pellizcar para hacer zoom** – Separa o junta dos dedos para hacer zoom.

**Girar** – Coloca dos dedos bien separados sobre la tableta y gíralos alrededor de su centro. Desplazar, hacer zoom y girar son lecturas distintas del mismo gesto con dos dedos, así que cada uno se activa o desactiva por separado.

**Invertir dirección** – On: el contenido se desplaza en sentido contrario al movimiento de los dedos, como una rueda de ratón clásica.

**Desplazamiento con inercia** – El desplazamiento con dos dedos continúa brevemente después de levantar los dedos, igual que la inercia de un trackpad.

## Área táctil

El área táctil funciona de forma independiente al área activa del lápiz. Arrastra los tiradores de la vista previa para recortar la superficie táctil disponible. La entrada de dedos fuera del rectángulo no tiene efecto.

**Restablecer a superficie completa** – Restablece el área táctil a toda la superficie compatible con tacto.

## Limitaciones

MockTab no admite Mission Control, Spaces, Launchpad ni App Exposé desde el tacto.

[display]

## Mapeo de pantalla

El mapeo de pantalla determina qué pantalla trata la tableta como activa.

**Todas las pantallas** – Mayús-clic en cualquier pantalla del diagrama para abarcar todo el escritorio de forma proporcional. Va bien para flujos de trabajo que se mueven entre varios monitores.

**Una sola pantalla** – Haz clic en una pantalla del diagrama para asignar el área activa solo a esa pantalla.

**Cambiar pantalla** – Cambia de pantalla con un botón. Haz ⌘-clic en las pantallas del diagrama para elegir cuáles recorre.

**Distribuir en pantallas** – Pulsa un botón con esta acción para distribuir el lápiz en las pantallas seleccionadas en Pantallas activas, y vuelve a pulsarlo para volver a tu ajuste habitual. Si no hay ninguna seleccionada, abarca todas las pantallas.

## Área de pantalla

Como el área activa, pero del lado de la pantalla: recorta la zona del display que el lápiz puede alcanzar.

**Seleccionar en pantalla…** – Arrastra la región directamente sobre tu escritorio, como con la herramienta de capturas de macOS.

**Usar pantalla completa** – Restablece el área a toda la pantalla.

[devices]

## Dispositivos conectados

El panel Devices muestra todas las tabletas y lápices que MockTab ha detectado. Cada fila indica el nombre del dispositivo, el tipo de conexión (USB o Bluetooth) y el estado actual.

Al seleccionar una fila de dispositivo, en el panel de detalles de la derecha aparecen los ajustes y lápices específicos de ese modelo.

Los dispositivos desconectados permanecen en la lista para que sus perfiles sigan disponibles para inspección o ajuste aunque estén desenchufados. Cuando un dispositivo de la lista vuelve a conectarse, MockTab aplica automáticamente su configuración guardada.

En una Intuos5 o Intuos Pro (2013) con el kit inalámbrico de Wacom, la fila **Batería** del panel Info establece cuánto tiempo puede estar la tableta sin usarse antes de entrar en reposo.

## Detección de conflictos

Si otro controlador de tabletas, como el controlador oficial de Wacom, se ejecuta al mismo tiempo, MockTab intenta detectar el conflicto y mostrar una advertencia.

[profiles]

## Perfiles

Un perfil es una instantánea de la configuración de la tableta: área activa, curva de presión, asignaciones de botones y mapeo de pantalla. Al cambiar de perfil, todos esos ajustes se aplican de inmediato.

## Crear y renombrar

Haz clic en **Crear perfil** para guardar la configuración actual como un perfil nuevo. Haz doble clic en el nombre de un perfil para cambiarlo.

## Overrides por app en los perfiles

Cada perfil guarda sus propios overrides por aplicación. Al cambiar de perfil, también cambian los overrides asociados al perfil activo.

## Copia de seguridad e importación

Arrastra el recuadro JSON al Finder para guardar todos los ajustes, incluidos números de serie y nombres de apps. Arrastra un archivo al recuadro para importarlo y elige qué tabletas incorporar. El menú Perfiles hace lo mismo.

[scratchpad]

## Área de prueba

Un lienzo de prueba para comprobar que el lápiz registra presión, inclinación y movimiento. MockTab no guarda los trazos.

[info]

## Entrada en vivo

El panel Info muestra lo que informa la tableta. Los indicadores representan la posición, la presión, la inclinación, la rotación, la altura de proximidad y la actividad táctil.

## Recopilar datos del dispositivo

**Recopilar datos del dispositivo** graba lo que la tableta envía mientras la usas. El resultado es un único archivo ZIP que puedes adjuntar a una solicitud en GitHub o enviar por correo electrónico para añadir o mejorar la compatibilidad con un dispositivo.

## Actualizaciones

**Buscar ahora** pregunta a mocktab.org si hay una versión más reciente, y **Buscar automáticamente** lo hace cada semana. Nada más se conecta a internet.

Una marca en los iconos de la barra de menús y del Dock indica que hay una actualización. **Instalar al salir** la instala cuando sales de MockTab, e **Instalar y reiniciar** la instala ahora.

## Dock e inicio de sesión

**Icono del Dock** – Oculta MockTab del Dock. El icono de la barra de menús se mantiene.

**Iniciar al acceder** – Abre MockTab al iniciar sesión.

**Conceder…** abre Ajustes del Sistema para un permiso que falta.

[website]

## mocktab.org

El sitio web [mocktab.org](https://mocktab.org) ofrece documentación, notas de versión y la lista completa del hardware compatible.

## GitHub

Los informes de errores y las preguntas van a [github.com/Cyzor/tablet-driver/issues](https://github.com/Cyzor/tablet-driver/issues).

## Agradecimientos

MockTab se apoya en trabajo de código abierto. [OpenTabletDriver](https://opentabletdriver.net/) aporta configuraciones de tabletas de muchas marcas. [Linux Wacom Project](https://linuxwacom.github.io/) aporta las dimensiones y la disposición de controles de Wacom a través de libwacom, y documenta los formatos de datos de Wacom con su controlador input-wacom, incluido también en el kernel de Linux, y su colección wacom-hid-descriptors.

## Licencia

MockTab es software libre bajo la [Licencia Pública General de GNU, versión 3 o posterior](https://www.gnu.org/licenses/gpl-3.0.html). Su código fuente está en [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver). TabletKit, la biblioteca con la que MockTab lee las tabletas, usa la [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).

Los dibujos de tabletas usan disposiciones de controles de libwacom:

Copyright © 2011 Red Hat, Inc.

Permission to use, copy, modify, distribute, and sell this software and its documentation for any purpose is hereby granted without fee, provided that the above copyright notice appear in all copies and that both that copyright notice and this permission notice appear in supporting documentation, and that the name of Red Hat not be used in advertising or publicity pertaining to distribution of the software without specific, written prior permission.  Red Hat makes no representations about the suitability of this software for any purpose.  It is provided "as is" without express or implied warranty.

THE AUTHORS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
