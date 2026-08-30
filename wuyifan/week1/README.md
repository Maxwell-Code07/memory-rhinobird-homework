“成功加载记忆插件.png”中，gateway出现recall、capture，说明provider已成功运行，出现"L0 recorded..."说明插件“大脑”已经成功运行。

"L1.png"中出现“2026-08-25T15:34:51.619+08:00 INF0 [tdai-gateway] [memory-tdai] [pipeline-factory] [l1] L1 complete: extracted=2, stored=2 (1 group(s))”说明L1画像成功提取

"L2.png"中出现“[L2] Extraction complete: processed=2”说明L2已经成功提取

“L3.png”中出现“[L3] Persona generation not needed”说明L3已经被成功调用，但系统判断不需要写入L3画像。

我对话了许多轮，发现都没有写入L3画像，并且每提取一次L1画像后，从L0提取到L1的对话轮数都增加1，所以就没有一直对话到成功提取L3了。
