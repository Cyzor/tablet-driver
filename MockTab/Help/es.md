[about]

## Tabletas gráficas

Una tableta gráfica es un dispositivo de entrada con lápiz que registra posición absoluta, presión, inclinación y rotación.

## MockTab

MockTab es un driver nativo de macOS para tabletas Wacom. Compatible con USB y Bluetooth en Intuos, Cintiq, Bamboo e Intuos Pro — hardware que Wacom ya no soporta en macOS moderno.

[tabletArea]

## Área activa

El área activa es la parte de la superficie que se mapea a tu pantalla. Entrada del lápiz fuera de este rectángulo se ignora.

**Redimensionar** — Arrastra cualquier control para reposicionar o cambiar el tamaño. **Shift** + arrastre de esquina bloquea proporción. Puedes escribir valores exactos en Width y Height.

**Lock Aspect Ratio** — Mantiene la proporción tableta-pantalla.

**Reset to Full** — Restaura el área a toda la superficie. Deshacer con ⌘Z.

## Calibración (Pen Displays)

**Calibrate** abre una superposición a pantalla completa para tocar dianas con la punta del lápiz. Corrige la brecha de paralaje del cristal.

Tras calibrar, usa **Manual Fine-Tune** si queda desplazamiento.

[penFeel]

## Curva de presión

La curva controla cómo se mapea presión del lápiz a salida. Cóncava (arriba) hace trazos suaves más fuertes; convexa (abajo) requiere más fuerza.

**Preajustes de Tip Feel** — Linear, Soft, Firm. Elige uno para establecer la curva; ajusta un punto para personalizar.

## Suavizado

Reduce vibraciones de alta frecuencia. Valores altos = trazos limpios con retraso; bajos = inmediatos. Usa cero para precisión.

## Distancia de doble clic

Define cuán cerca deben estar dos toques para ser doble clic. Aumenta si no se registran; disminuye si ocurren accidentales.

[buttons]

## Diagrama del lápiz

El diagrama muestra los botones del lápiz. Pulsa uno para verlo resaltado — identifica qué botón corresponde a qué asignación.

**Arrastre en hover** — Botón 1 (barrel inferior) + flotación = mueve cursor sin tocar punta.

## Tipos de asignación

- **Botones del ratón** — clic izquierdo, derecho, central o doble clic
- **Atajos de teclado** — haz clic en el campo de atajo y pulsa cualquier combinación de teclas
- **Modificadores mantenidos** — ⌘ ⌥ ⇧ ⌃ se mantienen mientras el botón esté pulsado
- **Acciones especiales** — Display Toggle, Eraser, selección de modo del Touch Ring

## Touch Ring

El anillo admite múltiples slots. Cada uno tiene acciones en sentido horario/antihorario — scroll, teclas, o apagado. **Ring Cycle** recorre modos; **Ring: Slot N** salta directo. **Multiplicador de velocidad** controla eventos por grado.

## Borrador

Punta de borrador tiene asignación propia (sección lápiz). La mayoría de apps cambian automáticamente al tool de borrado — sin configuración extra a menos que quieras anular.

## Overrides por app

La barra de overrides en la parte superior te permite asignar botones diferentes para una aplicación específica. Los overrides se activan automáticamente cuando esa app pasa a primer plano. La configuración global se aplica en todos los demás casos.

[touch]

## Toque con el dedo

Las tabletas con superficie táctil capacitiva detectan contactos del dedo además de la entrada del lápiz. MockTab mantiene esta función desactivada por defecto — activa **Habilitar toque con el dedo** para usarla.

**Toca para hacer clic** – Un toque breve sin movimiento significativo emite un clic izquierdo. Mantén esta opción desactivada si apoyas los dedos en la tableta al dibujar; de lo contrario, se producen clics fantasma.

**Velocidad del cursor** – Escala el movimiento del puntero al arrastrar con un solo dedo. 1,00× asigna el área táctil directamente a la pantalla; valores mayores recorren más distancia con menos movimiento, valores menores permiten control más fino.

## Desplazamiento

**Desplazamiento con dos dedos** – Dos dedos moviéndose juntos emiten eventos de desplazamiento suave. Las apps los tratan como desplazamiento de trackpad, incluido el efecto rubber-band en Safari y Vista Previa.

**Invertir dirección** – Activado: el contenido se desplaza en sentido contrario al movimiento de los dedos, como una rueda de ratón clásica. Desactivado (predeterminado): el contenido sigue a tus dedos.

## Área táctil

El área táctil funciona de forma independiente al área activa del lápiz. Arrastra los tiradores de la vista previa para recortar la superficie táctil; la entrada de dedo fuera del rectángulo no tiene efecto. La mayoría de los usuarios deja activa toda la superficie para el toque y recorta solo el área del lápiz.

**Restablecer a superficie completa** – Restaura el área táctil a toda la región táctil disponible.

## Lo que el toque no puede hacer

MockTab no puede emitir Mission Control, Spaces, Launchpad ni otros gestos multitáctiles del sistema. macOS reserva esos canales privados de eventos de trackpad para controladores de primera parte. Usa un trackpad o atajos de teclado para la navegación del sistema.

[display]

## Mapeo de pantalla

Controla a qué pantalla se mapea el área activa.

**All Displays** — tableta abarca todo el escritorio. Úsalo con varios monitores.

**Single Display** — mapea a pantalla específica. Elige de la lista; la vista previa se actualiza.

**Display Toggle** — asigna a tecla express o barrel para recorrer pantallas sin abrir preferencias.

[devices]

## Dispositivos conectados

El panel lista todas las tabletas y herramientas. Cada fila muestra nombre, tipo de conexión (USB/Bluetooth), estado.

## Registro de herramientas

MockTab registra código de herramienta al detectar lápiz. Código desconocido aparece como "Unknown tool". Asigna nombre y binding manualmente.

## Detección de conflictos

Si otro driver se ejecuta, MockTab detecta y advierte. Cierra el driver en conflicto antes de usar MockTab.

[profiles]

## Perfiles

Un perfil guarda toda tu configuración — área activa, curva presión, botones, mapeo pantalla. El cambio es instantáneo.

**Auto-restore** — activa el interruptor para activar automáticamente al conectar.

## Crear y renombrar

**Save as New Profile** para guardar. Doble clic en nombre para renombrar.

## Overrides por app en perfiles

Los overrides se guardan con el perfil. Al cambiar, cambian juntos.

## Importar / Exportar

Arrastra tarjeta al Finder para exportar JSON. Arrastra JSON sobre la lista para importar. Comparte o usa como backup.

[scratchpad]

## Scratchpad

Lienzo de prueba sensible a presión. Opacidad y grosor responden a presión; inclinación afecta ángulo (si compatible). Los trazos no se guardan.

**Clear** — elimina todos los trazos. No se puede deshacer.

[info]

## Entrada en directo

El panel Info muestra valores en tiempo real: X/Y, presión, inclinación, rotación, hover, botones. Diagnóstico de comportamientos inesperados.

**Jitter** muestra delta de posición medio. Valores sostenidos arriba del baseline indican interferencia RF, batería baja o problema hardware.

## Diagnóstico

**Collect Device Data** ejecuta una sesión de captura guiada que graba los reportes HID en bruto. El resultado es un archivo JSON compacto para adjuntar a solicitudes de soporte.

[website]

## mocktab.org

[mocktab.org](https://mocktab.org) — documentación, notas de versión, hardware compatible.

## GitHub

Reportes y preguntas a [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues). Adjunta el archivo JSON de **Collect Device Data** a tus solicitudes de soporte.
