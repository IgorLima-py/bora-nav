"""The log in both languages (C16.10b): Portuguese log lines rewritten in English.

Up to v1.4.0 (watch) and 1.4.0 (phone) the apps logged in Portuguese; from v1.4.1 and 1.4.1 they log
in English. The tools match the English text only, and call :func:`to_english` on what they read, so a
log from either version gives the same result.

Only the phrases some tool reads are here; the rest of an old log stays as it was. Each pattern is the
Portuguese the old code wrote, and its replacement is what the new code writes (same values, same
separators), so ``to_english`` on an English log changes nothing.

    from logphrases import to_english
    text = to_english(path.read_text(encoding="utf-8"))
"""
from __future__ import annotations

import re

#: (old Portuguese, new English), applied in this order. Longer phrases come before the shorter ones
#: they contain (``vibra fora da rota`` before ``fora da rota``, before ``rota``).
_TABLE: list[tuple[str, str]] = [
    # --- watch: the demo and test apps' tagged lines (tools/sim.py)
    (r"\[ride\] inicio ", "[ride] start "),
    (r"\[ride\] manobra (\d+) tipo (\d+) em ", r"[ride] maneuver \1 type \2 at "),
    (r"\[ride\] fim (.+) em (\d+) fixes", r"[ride] end \1 in \2 fixes"),
    (r"\[ride\] ruas", "[ride] streets"),
    (r"\[track\] inicio ", "[track] start "),
    (r"\[track\] fim (.+) em (\d+) fixes", r"[track] end \1 in \2 fixes"),
    (r"\[track\] gravador (\d+) perdi ", r"[track] recorder \1 lost "),
    (r"\[demo\] pronto", "[demo] ready"),
    (r"\[shot\] pronto", "[shot] ready"),
    (r"\[detalhes\] pronto (\d+) manobras", r"[details] ready \1 maneuvers"),
    (r"\[detalhes\]", "[details]"),
    (r"\[inicio\] pronto", "[home] ready"),
    (r"\[inicio\]", "[home]"),
    (r"\[burnin\] pronto (\w+) ponto ", r"[burnin] ready \1 point "),
    (r"\[setas\] pronto", "[arrows] ready"),
    (r"\[setas\]", "[arrows]"),
    (r"\[traco\] pronto", "[trace] ready"),
    (r"\[traco\]", "[trace]"),
    (r"\bprobe (\d+) inicio", r"probe \1 start"),
    (r"\bprobe fim sem morrer", "probe end alive"),
    (r" pts (\d+) manobras ", r" pts \1 maneuvers "),
    # --- watch: the [diag] lines
    (r"\bvibra curva (\d+) aviso (\d) a ", r"vibe turn \1 alert \2 at "),
    (r"\bvibra chegada", "vibe arrival"),
    (r"\bvibra fora da rota", "vibe off route"),
    (r"\bvibra radar (\d+) a ", r"vibe radar \1 at "),
    (r"\bvibra ", "vibe "),
    (r"\bchegou ao destino a ", "arrived at destination at "),
    (r"\bhud clima ", "hud weather "),
    (r"\bhud seta de volta", "hud arrow back"),
    (r"\bhud Recalculando", "hud Recalculating"),
    (r"\bhud Sem celular", "hud No phone"),
    (r"\bde volta a rota", "back on route"),
    (r"\bfora da rota ", "off route "),
    (r"\bfix do celular: inicio, precisao (\d+)m, idade ", r"phone fix: start, accuracy \1m, age "),
    (r"\bfix do celular: fim apos ", "phone fix: end after "),
    (r"\bfix do celular fraco: precisao ", "phone fix weak: accuracy "),
    (r"\bburaco de fix ", "fix gap "),
    (r"\bfix voltou apos ", "fix back after "),
    (r"\bsem fix ha ", "no fix for "),
    (r"\bfavoritos (\d+) aplicados", r"favorites \1 applied"),
    (r"\bfavoritos abertos: ", "favorites opened: "),
    (r"\brecentes abertos: ", "recents opened: "),
    (r"\beta recusado rota ", "eta refused route "),
    (r"\bcorredor lod ", "corridor lod "),
    (r"\bwork pico ", "work peak "),
    (r"\bframe med (\d+)ms pico ", r"frame avg \1ms peak "),
    (r"\bCORTOU\b", "CAPPED"),
    (r"\bdiagnostico das ruas", "streets diagnostics"),
    (r"\brota trocada (\d+) -> (\d+) em ", r"route swapped \1 -> \2 in "),
    (r"\brota trocada (\d+) -> (\d+) sem pedido", r"route swapped \1 -> \2 unrequested"),
    (r"\brota trocada ", "route swapped "),
    (r"\brota encerrada", "route ended"),
    (r"\bcompleta (\d+)B ", r"complete \1B "),
    (r"\bradares (\d+) rota ", r"radars \1 route "),
    (r"\bradar (\d+) na tela: ", r"radar \1 on screen: "),
    (r"\btrilha (\d+) fixes perdi ", r"trail \1 fixes lost "),
    (r"\btrilha ", "trail "),
    # the telemetry line (``Telemetry.line``): ``fase navegando · tela mapa · rota N Npts · corredor N lods
    # N pts N na tela · zoom Z · na rota · Nkm/h · ... · fix celular``
    (r"\bfase navegando ", "phase navigating "),
    (r"\bfase chegou ", "phase arrived "),
    (r"\bfase recebendo ", "phase receiving "),
    (r"\bfase parado ", "phase idle "),
    (r"\bfase (\w+) ", r"phase \1 "),
    (r" · tela mapa", " · screen map"),
    (r" · tela transferencia", " · screen transfer"),
    (r" · tela inicial", " · screen initial"),
    (r" · tela ", " · screen "),
    (r" · corredor (\d+) lods ", r" · corridor \1 lods "),
    (r" pts (\d+) na tela", r" pts \1 on screen"),
    (r" · na rota · ", " · on route · "),
    (r" · fora · ", " · off · "),
    (r" · sem fix · ", " · no fix · "),
    (r" · fix celular\b", " · fix phone"),
    (r"\bponte ", "bridge "),
    # --- phone (EventLog: logcat and motonav.log)
    (r"\bRELÓGIO\|", "WATCH|"),
    (r"\brota do Mapbox pronta em ", "Mapbox route ready in "),
    (r"\bsem resposta do Mapbox", "no response from Mapbox"),
    (r"\benviando rota (\d+) para ", r"sending route \1 to "),
    (r"\bTOTAL compartilhar -> rota no relógio: ", "TOTAL share -> route on watch: "),
    (r" \(FALHOU\)", " (FAILED)"),
    (r"\bcorredor: (\d+) segmentos em ", r"corridor: \1 segments in "),
    (r"\bcorredor enviado ao relógio: ", "corridor sent to watch: "),
    (r"\bIniciar tocado (\d+) ms depois do compartilhamento", r"Start tapped \1 ms after the share"),
    (r"--- sessão ", "--- session "),
    (r"\bbloco (0x[0-9A-F]{2}) completo após (\d+) rodadas", r"block \1 complete after \2 rounds"),
    (r"\bbloco (0x[0-9A-F]{2}) rodada (\d+): queda no chunk ", r"block \1 round \2: drop at chunk "),
    (r"\bbloco (0x[0-9A-F]{2}) rodada ", r"block \1 round "),
    (r"\b(\d+) radares do cache para a rota (\d+), enviados: ", r"\1 radars from cache for route \2, sent: "),
    (r"\b(\d+) radares da rota (\d+) na tentativa (\d+) em (\d+) ms, enviados: ",
     r"\1 radars of route \2 on attempt \3 in \4 ms, sent: "),
    (r"\bPHONE_FIX enviado: idade (\d+) ms, precisão ", r"PHONE_FIX sent: age \1 ms, accuracy "),
    (r"\bPHONE_FIX desligado: (.+), (\d+) fixes em ", r"PHONE_FIX off: \1, \2 fixes in "),
    (r"\bPHONE_FIX indisponível: ", "PHONE_FIX unavailable: "),
    (r"\bem primeiro plano: pid (\d+), tipo ", r"in foreground: pid \1, type "),
    (r"\brota (\d+) do favorito (\d+) NÃO enviada em ", r"route \1 of favorite \2 NOT sent in "),
    (r"\brota (\d+) do favorito (\d+) enviada em ", r"route \1 of favorite \2 sent in "),
    (r"\bROUTE_UPDATE rota (\d+) entregue: ", r"ROUTE_UPDATE route \1 delivered: "),
    (r"\bROUTE_UPDATE rota (\d+) não entregue", r"ROUTE_UPDATE route \1 not delivered"),
    (r"\bROUTE_UPDATE rota (\d+) sem duração nova", r"ROUTE_UPDATE route \1 no new duration"),
    (r"\bROUTE_UPDATE rota (\d+) pulado", r"ROUTE_UPDATE route \1 skipped"),
    (r"\bROUTE_UPDATE rota (\d+) mantido", r"ROUTE_UPDATE route \1 kept"),
    (r"\bsessão encerrada", "session ended"),
    (r"\bconfig recusada", "config refused"),
    (r"\bfavoritos recusados", "favorites refused"),
    (r"\bfalhou: ", "failed: "),
    # the phone's radar line (``RadarClient.radarLine``) and the cut summary
    (r"\b(lim \d+) rumo (\d+) sentido ida fonte ", r"\1 bearing \2 direction fwd source "),
    (r"\b(lim \d+) rumo (\d+) sentido (\S+) fonte ", r"\1 bearing \2 direction \3 source "),
    (r"\bradares cortados ", "radars cut "),
    # from the B2 batch (tools that read these lines)
    ('\\[demo\\] fim', '[demo] end'),
    ('\\[shot\\] fim', '[shot] end'),
    ('\\[burnin\\] fim', '[burnin] end'),
    ('\\[burnin\\] corte amplitude (\\d+) cortadas (\\d+) de (\\d+) orcamento (-?\\d+) maior (\\d+)', '[burnin] cut amplitude \\1 cut \\2 of \\3 budget \\4 widest \\5'),
    ('\\[(detalhes|details)\\] fim', '[details] end'),
    ('\\[(inicio|home)\\] fim', '[home] end'),
    ('\\[(setas|arrows)\\] fim', '[arrows] end'),
    ('\\[(traco|trace)\\] fim', '[trace] end'),
    ('\\[(ride|track)\\] end chegada in ', '[\\1] end arrival in '),
    ('\\[(ride|track)\\] fim chegada em ', '[\\1] end arrival in '),
    ('\\bmapa on\\b', 'map on'),
    ('\\bconfig padrao\\b', 'config default'),
    ('\\b(config [^\\n]*?) aplicado\\b', '\\1 applied'),
    ('\\b(config [^\\n]*?) restaurado do Storage', '\\1 restored from Storage'),
    # from the B3 batch (tools that read these lines)
    ('\\bLinkResolver: compartilhado:', 'LinkResolver: shared:'),
    ('\\bMapboxProvider: rota (?=-?\\d)', 'MapboxProvider: route '),
    ('\\bShareReceiver: aguardando confirmação', 'ShareReceiver: awaiting confirmation'),
    ('\\bnovo compartilhamento com a tela aberta \\(onNewIntent\\)', 'new share with the screen open (onNewIntent)'),
    ('\\bnenhum ACK em ', 'no ACK in '),
    ('\\bsem corredor nesta rota depois de', 'no corridor on this route after'),
    ('\\btodos os (\\d+) espelhos do Overpass falharam', 'all \\1 Overpass mirrors failed'),
    (': os mesmos do cache', ': same as the cache'),
    ('\\bRerouteController: nenhum radar na (?:rota|route) ', 'RerouteController: no radar on route '),
    ('\\bsem radares do Overpass nesta rota depois de', 'no radars from Overpass on this route after'),
    ('\\bPHONE_FIX ligado', 'PHONE_FIX on'),
    (', em (-?\\d+),(-?\\d+) a (\\d+) dm/s rumo ', ', at \\1,\\2 at \\3 dm/s heading '),
    ('\\bPHONE_FIX não saiu', 'PHONE_FIX not sent'),
    ('\\bo relógio dispensou', 'the watch dismissed it'),
    ('\\bo serviço em primeiro plano não tem o tipo location', 'the foreground service does not have the location type'),
    ('\\bNavService: sem o tipo location', 'NavService: without the location type'),
    ('\\bNavService: encerrado', 'NavService: ended'),
    ('\\breiniciado pelo sistema', 'restarted by the system'),
    ('\\bTokenReceiver: token gravado', 'TokenReceiver: token saved'),
    ('\\bprimeiro uso: aberto', 'first run: opened'),
    ('\\bprimeiro uso: concluído', 'first run: done'),
    ('\\bsimulacao inicio', 'simulation start'),
    ('\\bsimulacao fim: chegada', 'simulation end: arrival'),
    ('\\bsimulacao fim: ', 'simulation end: '),
    ('\\brecalcular precisa do celular', 'recalculation needs the phone'),
    (' do corredor repetido: ignorado', ' of corridor repeated: ignored'),
    # --- last: a route id after any other word (``poly rota``, ``eta rota``, the phone's ``radar i/n rota``)
    (r"\brota (\d+)", r"route \1"),
]

_COMPILED = [(re.compile(p), r) for p, r in _TABLE]


def to_english(text: str) -> str:
    """``text`` with every Portuguese log phrase of the table in its English form."""
    for pattern, repl in _COMPILED:
        text = pattern.sub(repl, text)
    return text
