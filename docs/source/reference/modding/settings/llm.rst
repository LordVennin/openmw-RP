LLM Settings
############

Settings of the local LLM server used by the openmw.llm package for AI dialogue.
Requests are only ever sent to 127.0.0.1.

.. omw-setting::
   :title: server autostart
   :type: boolean
   :range: true, false
   :default: true

   Start the bundled llama-server when the game starts and stop it when the game exits.
   If a server already answers on :ref:`port`, that server is used instead.

.. omw-setting::
   :title: server path
   :type: string
   :default: ""

   Path to the llama-server executable.
   Empty uses the one bundled in the ``llama`` folder next to the openmw executable.

.. omw-setting::
   :title: models folder
   :type: string
   :default: ""

   Folder where models are kept and where the launcher downloads them.
   Empty uses a ``models`` folder next to the openmw executable,
   or the ``models`` folder of the user data directory if the game's folder is not writable.

.. omw-setting::
   :title: model
   :type: string
   :default: ""

   Path to the model file (.gguf). Empty uses the first .gguf file in the models folder.

.. omw-setting::
   :title: device
   :type: string
   :default: auto

   Device the model runs on: ``auto`` picks the best GPU found (CUDA, then ROCm, then Vulkan),
   ``cpu`` runs on the processor only, and any other value is a device name listed by
   ``llama-server --list-devices``, such as ``CUDA0`` or ``Vulkan0``.

.. omw-setting::
   :title: context size
   :type: int
   :range: 2048 to 1048576
   :default: 8192

   Context size in tokens. It is passed to llama-server and sets the prompt budget of AI dialogue.
   Larger contexts let NPCs know and remember more, but use more video memory.

.. omw-setting::
   :title: gpu layers
   :type: int
   :range: -1 to 999
   :default: -1

   Number of model layers run on the GPU; the rest run on the CPU, which is much slower.
   -1 puts as many layers on the GPU as fit while keeping :ref:`vram reserve` free.

.. omw-setting::
   :title: vram reserve
   :type: int
   :range: 0 to 65536
   :default: 3072

   With automatic GPU layers, the video memory in MiB kept free for the game and its mods.
   Raise it when using texture or mesh replacers.

.. omw-setting::
   :title: port
   :type: int
   :range: 1 to 65535
   :default: 8080

   Port of an already running server to use.
   The bundled server picks the first free port starting here.

.. omw-setting::
   :title: extra arguments
   :type: string
   :default: ""

   Extra command line arguments for the bundled llama-server, separated by spaces.
