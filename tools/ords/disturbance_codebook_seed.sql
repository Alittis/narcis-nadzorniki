--------------------------------------------------------------------------------
-- Seed the global disturbance codebook (groups + types, ORG_ID NULL).
--
-- Data sourced from lib/data/disturbance_types.dart on this iteration. Until
-- a server-side codebook editor + a /codebook fetch endpoint exists (PDF §6.c.ii,
-- not in scope this iteration), the canonical copy is the Dart file - keep
-- this script in step with it manually when you change the Dart source.
--
-- Idempotent: re-running upserts on (skupina_koda, tip_koda, ORG_ID NULL) and
-- updates IME / POJASNILO if the source text changed. Per-org additions
-- (ORG_ID non-null) are NOT touched here; parks add those through their own
-- admin path.
--------------------------------------------------------------------------------

DECLARE
  PROCEDURE seed_skupina(p_koda IN VARCHAR2, p_ime IN VARCHAR2) IS
  BEGIN
    MERGE INTO tb_sif_motnje_skupine d
    USING (SELECT p_koda AS skupina_koda FROM dual) s
       ON (d.skupina_koda = s.skupina_koda)
     WHEN MATCHED THEN UPDATE SET d.ime = p_ime
     WHEN NOT MATCHED THEN
       INSERT (skupina_koda, ime) VALUES (p_koda, p_ime);
  END;

  PROCEDURE seed_tip(
    p_skupina   IN VARCHAR2,
    p_tip       IN VARCHAR2,
    p_ime       IN VARCHAR2,
    p_pojasnilo IN VARCHAR2 DEFAULT NULL
  ) IS
    l_id NUMBER;
  BEGIN
    SELECT tip_id INTO l_id
      FROM tb_sif_motnje_tipi
     WHERE skupina_koda = p_skupina
       AND tip_koda     = p_tip
       AND org_id       IS NULL;
    UPDATE tb_sif_motnje_tipi
       SET ime = p_ime, pojasnilo = p_pojasnilo
     WHERE tip_id = l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      INSERT INTO tb_sif_motnje_tipi
        (tip_id, skupina_koda, tip_koda, ime, pojasnilo, org_id)
      VALUES
        (tb_sif_motnje_tipi_seq.NEXTVAL, p_skupina, p_tip, p_ime, p_pojasnilo, NULL);
  END;
BEGIN
  -- 1. Sprehajalci
  seed_skupina('1', 'Sprehajalci');
  seed_tip('1', 'a', 'Ljudje izven poti');
  seed_tip('1', 'b', 'Ljudje na poteh');
  seed_tip('1', 'c', 'Pes na povodcu');
  seed_tip('1', 'd', 'Spuščen pes');
  seed_tip('1', 'e', 'Potepuška mačka');
  seed_tip('1', 'f', 'Drsalci');
  seed_tip('1', 'g', 'Fotograf');
  seed_tip('1', 'h', 'Fotograf v maskirnem šotoru');
  seed_tip('1', 'i', 'Konjenik');
  seed_tip('1', 'j', 'Opazovalec ptic');
  seed_tip('1', 'k', 'Detektorist');
  seed_tip('1', 'l', 'Hrup obiskovalcev');
  seed_tip('1', 'm', 'Sprehajalci drugo');

  -- 2. Kopalci
  seed_skupina('2', 'Kopalci');
  seed_tip('2', 'a', 'Kopalci');
  seed_tip('2', 'b', 'Kopanje psa');
  seed_tip('2', 'c', 'Kopalci drugo');

  -- 3. Prireditve in snemanja
  seed_skupina('3', 'Prireditve in snemanja');
  seed_tip('3', 'a', 'Športna prireditev');
  seed_tip('3', 'b', 'Kulturna prireditev');
  seed_tip('3', 'c', 'Zabavna prireditev');
  seed_tip('3', 'd', 'Prireditev z ozvočenjem');
  seed_tip('3', 'e', 'Snemanje, manjša ekipa (do 5 oseb)');
  seed_tip('3', 'f', 'Snemanje, večja ekipa (nad 5 oseb)');
  seed_tip('3', 'g', 'Prireditve drugo');

  -- 4. Vožnja v naravi
  seed_skupina('4', 'Vožnja v naravi');
  seed_tip('4', 'a', 'Kolesa');
  seed_tip('4', 'b', 'Motorji');
  seed_tip('4', 'c', 'Štirikolesniki');
  seed_tip('4', 'd', 'Avtomobili');
  seed_tip('4', 'e', 'Tovorna vozila');
  seed_tip('4', 'f', 'Traktorji');
  seed_tip('4', 'g', 'Motorne sani');
  seed_tip('4', 'h', 'Gradbena mehanizacija');
  seed_tip('4', 'i', 'Vožnja v naravi drugo');

  -- 5. Vožnja po cestah/kolovozih
  seed_skupina('5', 'Vožnja po cestah/kolovozih');
  seed_tip('5', 'a', 'Kolesa');
  seed_tip('5', 'b', 'Motorji');
  seed_tip('5', 'c', 'Štirikolesniki');
  seed_tip('5', 'd', 'Avtomobili');
  seed_tip('5', 'e', 'Tovorna vozila');
  seed_tip('5', 'f', 'Traktorji');
  seed_tip('5', 'g', 'Avtodomi');
  seed_tip('5', 'h', 'Konjska vprega');
  seed_tip('5', 'i', 'Vožnja po cestah/kolovozih drugo');

  -- 6. Plovba
  seed_skupina('6', 'Plovba');
  seed_tip('6', 'a', 'Čoln na vesla');
  seed_tip('6', 'b', 'Sup');
  seed_tip('6', 'c', 'Motorni čoln');
  seed_tip('6', 'd', 'Spuščanje modelov čolnov');
  seed_tip('6', 'e', 'Jadranje');
  seed_tip('6', 'f', 'Vodni skuter');
  seed_tip('6', 'g', 'Kajt / deskar s padalom');
  seed_tip('6', 'h', 'Surf / deska');
  seed_tip('6', 'i', 'Plovba drugo');

  -- 7. Zrakoplovi
  seed_skupina('7', 'Zrakoplovi');
  seed_tip('7', 'a', 'Droni');
  seed_tip('7', 'b', 'Letala');
  seed_tip('7', 'c', 'Helikopterji');
  seed_tip('7', 'd', 'Motorni zmaji');
  seed_tip('7', 'e', 'Jadralna padala, zmaji');
  seed_tip('7', 'f', 'Spuščanje modelov letal');
  seed_tip('7', 'g', 'Zrakoplovi drugo');

  -- 8. Taborjenje
  seed_skupina('8', 'Taborjenje');
  seed_tip('8', 'a', 'Piknik v naravi');
  seed_tip('8', 'b', 'Šotori');
  seed_tip('8', 'c', 'Avtodomi');
  seed_tip('8', 'd', 'Kurišče');
  seed_tip('8', 'e', 'Preživetje v naravi, enodnevno');
  seed_tip('8', 'f', 'Preživetje v naravi, večdnevno');
  seed_tip('8', 'g', 'Kamp prikolica');
  seed_tip('8', 'h', 'Viseče mreže');
  seed_tip('8', 'i', 'Taborjenje drugo');

  -- 9. Lov
  seed_skupina('9', 'Lov');
  seed_tip('9', 'a', 'Lovci ki streljajo');
  seed_tip('9', 'b', 'Lovci ki ne streljajo');
  seed_tip('9', 'c', 'Lovska preža');
  seed_tip('9', 'd', 'Lovec v lovski preži');
  seed_tip('9', 'e', 'Lovsko skrivališče');
  seed_tip('9', 'f', 'Lovci na čolnu');
  seed_tip('9', 'g', 'Lovski pogon');
  seed_tip('9', 'h', 'Domnevno streljanje');
  seed_tip('9', 'i', 'Lovski pes');
  seed_tip('9', 'j', 'Tulci nabojev');
  seed_tip('9', 'k', 'Lovska vaba',
           'Mišljeni so modeli divjadi (npr. rac) in predvajalniki oglašanja za privabljanje divjadi.');
  seed_tip('9', 'l', 'Krmišče za divjad');
  seed_tip('9', 'm', 'Solnica za divjad');
  seed_tip('9', 'n', 'Mreža za lov ptic');
  seed_tip('9', 'o', 'Past');
  seed_tip('9', 'p', 'Lov drugo');

  -- 10. Ribolov
  seed_skupina('10', 'Ribolov');
  seed_tip('10', 'a', 'Ribolov z brega');
  seed_tip('10', 'b', 'Krapolov');
  seed_tip('10', 'c', 'Ribolov iz čolna');
  seed_tip('10', 'd', 'Ribolov z mrežo');
  seed_tip('10', 'e', 'Reševanje rib');
  seed_tip('10', 'f', 'Ribolov drugo');

  -- 11. Vojska
  seed_skupina('11', 'Vojska');
  seed_tip('11', 'a', 'Hrup eksplozij');
  seed_tip('11', 'b', 'Hrup streljanja');
  seed_tip('11', 'c', 'Vojaško letalo');
  seed_tip('11', 'd', 'Vojaški helikopter');
  seed_tip('11', 'e', 'Vojaško vozilo');
  seed_tip('11', 'f', 'Hrup reaktivnih letal');
  seed_tip('11', 'g', 'Vojska drugo');

  -- 12. Kadavri in poškodovane živali
  seed_skupina('12', 'Kadavri in poškodovane živali');
  seed_tip('12', 'a', 'Odvzemanje osebkov',
           'Vključuje izkopavanje in trganje rastlin, odvzemanje jajc ali osebkov ...');
  seed_tip('12', 'b', 'Lokacija povoza dvoživk');
  seed_tip('12', 'c', 'Žrtev prometa (živali, ki niso dvoživke)');
  seed_tip('12', 'd', 'Kadaver',
           'Vključno z okostjem ali deli živalskih teles.');
  seed_tip('12', 'e', 'Poškodovana žival');
  seed_tip('12', 'f', 'Odlagališče klavnih odpadkov');
  seed_tip('12', 'g', 'Kadavri drugo');

  -- 13. Raziskave
  seed_skupina('13', 'Raziskave');
  seed_tip('13', 'a', 'Nočni popis ptic');
  seed_tip('13', 'b', 'Dnevni popis ptic');
  seed_tip('13', 'c', 'Popis ribjih vrst');
  seed_tip('13', 'd', 'Popis bentoških nevretenčarjev');
  seed_tip('13', 'e', 'Popis rastlin');
  seed_tip('13', 'f', 'Popis dvoživk');
  seed_tip('13', 'g', 'Monitoring žuželk');
  seed_tip('13', 'h', 'Raziskave tal');
  seed_tip('13', 'i', 'Raziskave drugo');

  -- 14. Kmetijstvo
  seed_skupina('14', 'Kmetijstvo');
  seed_tip('14', 'a', 'Gnojenje',
           'V opisu navedemo vrsto gnojenja, npr.: gnojnica, umetno gnojilo, hlevski gnoj, kurji gnoj ...');
  seed_tip('14', 'b', 'Košnja',
           'V opisu navedemo kakšen morebitni problem predstavlja.');
  seed_tip('14', 'c', 'Nepospravljeni odkos');
  seed_tip('14', 'd', 'Zavržene bale',
           'Vključno z zapuščenimi nepospravljenimi balami.');
  seed_tip('14', 'e', 'Koscem neprijazna košnja',
           'T.j. košnja od zunaj navznoter (a brez rešilnega otoka).');
  seed_tip('14', 'f', 'Mulčenje');
  seed_tip('14', 'g', 'Preoravanje',
           'Vključuje čiščenje plugov z oranjem brazd po jezeru.');
  seed_tip('14', 'h', 'Kopanje osuševalnih jarkov');
  seed_tip('14', 'i', 'Deponija hlevskega gnoja');
  seed_tip('14', 'j', 'Deponija bal');
  seed_tip('14', 'k', 'Kurjenje starine/trstišč');
  seed_tip('14', 'l', 'Utrjevanje kolovozov');
  seed_tip('14', 'm', 'Nasipanje',
           'Mišljeno je nasipanje za namene melioracije kmetijskih zemljišč in ne odlaganje odvečne zemljine ali gradbenih odpadkov - za te glej »Deponije«. Vključuje zasipanje depresij, mokrišč, vodnih kotanj ...');
  seed_tip('14', 'n', 'Odstranjevanje skal');
  seed_tip('14', 'o', 'Brananje');
  seed_tip('14', 'p', 'Melioracija travnika',
           'Lomljenje ali odstranjevanje skal na travniku, planiranje površine ipd.');
  seed_tip('14', 'q', 'Odstranjevanje mejic',
           'Sekanje mejic, posek zarasti med kmetijskimi zemljišči.');
  seed_tip('14', 'r', 'Odkop ruše');
  seed_tip('14', 's', 'Kmetijstvo drugo');

  -- 15. Gozdarstvo
  seed_skupina('15', 'Gozdarstvo');
  seed_tip('15', 'a', 'Nega');
  seed_tip('15', 'b', 'Sadnja');
  seed_tip('15', 'c', 'Sečnja');
  seed_tip('15', 'd', 'Spravilo lesa');
  seed_tip('15', 'e', 'Izdelava, obnova gozdne vlake');
  seed_tip('15', 'f', 'Deponija hlodovine');
  seed_tip('15', 'g', 'Gozdarstvo drugo');

  -- 16. Vode
  seed_skupina('16', 'Vode');
  seed_tip('16', 'a', 'Zajezitve');
  seed_tip('16', 'b', 'Poškodovan jez/nasip');
  seed_tip('16', 'c', 'Novonastali požiralniki');
  seed_tip('16', 'd', 'Zasipanje požiralnikov');
  seed_tip('16', 'e', 'Prekopi & regulacije');
  seed_tip('16', 'f', 'Čiščenje vodotokov',
           'Vključuje odstranjevanje obrežne vegetacije, poglabljanje struge ...');
  seed_tip('16', 'g', 'Pranje cistern z gnojnico');
  seed_tip('16', 'h', 'Pranje vozil',
           'Velja za pranje vozil ob reki ali jezeru.');
  seed_tip('16', 'i', 'Izlivanje gnojnice',
           'Vključuje izlivanje komunalnih odplak iz greznic ...');
  seed_tip('16', 'j', 'Zaprta zapirnica');
  seed_tip('16', 'k', 'Zasipanje fosilnih strug');
  seed_tip('16', 'l', 'Vode drugo');

  -- 17. Odlagališča
  seed_skupina('17', 'Odlagališča');
  seed_tip('17', 'a', 'Odložena zemljina');
  seed_tip('17', 'b', 'Odloženi gradbeni odpadki');
  seed_tip('17', 'c', 'Odlagališče zelenega odreza');
  seed_tip('17', 'd', 'Odloženi komunalni odpadki');
  seed_tip('17', 'e', 'Kurjenje odpadkov');
  seed_tip('17', 'f', 'Smetenje');
  seed_tip('17', 'g', 'Kosovni odpadki',
           'Pohištvo, vzmetnice, večji gospodinjski aparati ipd.');
  seed_tip('17', 'h', 'Odloženi avtomobilski deli');
  seed_tip('17', 'i', 'Odlagališča drugo');

  -- 18. Infrastruktura za obiskovalce
  seed_skupina('18', 'Infrastruktura za obiskovalce');
  seed_tip('18', 'a', 'Poškodovan element');
  seed_tip('18', 'b', 'Znaki propadanja elementa');
  seed_tip('18', 'c', 'Element odstranjen');
  seed_tip('18', 'd', 'Pot zaraščena');
  seed_tip('18', 'e', 'Infrastruktura za obiskovalce drugo');

  -- 19. Objekti
  seed_skupina('19', 'Objekti');
  seed_tip('19', 'a', 'Vikendice');
  seed_tip('19', 'b', 'Kamp prikolica');
  seed_tip('19', 'c', 'Gospodarski objekti');
  seed_tip('19', 'd', 'Ceste');
  seed_tip('19', 'e', 'Mostovi & brvi');
  seed_tip('19', 'f', 'Jezovi');
  seed_tip('19', 'g', 'Kolesarska downhill steza');
  seed_tip('19', 'h', 'Telekomunikacijska infrastruktura');
  seed_tip('19', 'i', 'Objekti drugo');

  COMMIT;
END;
/
