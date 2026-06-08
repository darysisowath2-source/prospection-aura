-- ============================================================================
--  DURCISSEMENT SUPABASE — prospection-aura
--  Projet : znefwyfmbtsencpylehv (PARTAGE avec le SaaS InkBook — voir SECTION 3)
--  Audit + corrections : branche fix/stabilisation
-- ============================================================================
--
--  CONSTAT (audit boite noire + introspection) :
--   - RLS est ACTIVE sur prospects_statuts / _historique / _enrichissement,
--     MAIS les policies etaient "public" / USING(true) sur SELECT *et* ALL
--     => le role anon (cle publique, presente dans le repo public + le HTML)
--        avait lecture + insertion + modification + SUPPRESSION sur tout.
--   - Volumetrie : ~5871 statuts, ~5826 enrichissements, ~398 historique.
--   - Colonne rappel_at ABSENTE alors que le code l'utilise (feature cassee).
--   - updated_at etait pose par l'horloge du navigateur (skew possible).
--
-- ============================================================================
--  SECTION 1 — DEJA APPLIQUE (2026-06, sans risque, app non impactee)
-- ============================================================================

-- 1.a  Repare la fonctionnalite "Rappeler +Nj" (colonne manquante)
alter table public.prospects_statuts add column if not exists rappel_at timestamptz;

-- 1.b  updated_at gere cote SERVEUR (fin de la dependance a l'horloge client) [H4]
create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists trg_set_updated_at on public.prospects_statuts;
create trigger trg_set_updated_at before update on public.prospects_statuts
  for each row execute function public.set_updated_at();

-- 1.c  Retire le droit DELETE au role "public" sur les 3 tables (l'app ne supprime
--      jamais ; le pipeline Python passe par la service_role qui ignore la RLS).
--      On remplace la policy "public write" (ALL) par INSERT + UPDATE uniquement.
do $$ declare t text;
begin
  foreach t in array array['prospects_statuts','prospects_historique','prospects_enrichissement'] loop
    execute format('drop policy if exists "public write" on public.%I', t);
    execute format('drop policy if exists "public insert" on public.%I', t);
    execute format('drop policy if exists "public update" on public.%I', t);
    execute format('create policy "public insert" on public.%I for insert to public with check (true)', t);
    execute format('create policy "public update" on public.%I for update to public using (true) with check (true)', t);
  end loop;
end $$;
-- Verifie : anon ne peut plus supprimer (delete touche 0 ligne, la donnee survit).

-- ============================================================================
--  SECTION 2 — A FAIRE : confidentialite des donnees prospection
--  (les donnees restent lisibles/modifiables par QUICONQUE a la cle anon)
--  Le vrai correctif demande une AUTHENTIFICATION cote app (Supabase Auth).
--  NE PAS appliquer tel quel tant que l'app utilise la cle anon, sinon elle casse.
-- ============================================================================
--
--  Etapes :
--   1) Ajouter Supabase Auth a l'app (magic link email pour Dary + Ami).
--   2) Utiliser la cle anon SEULEMENT pour se connecter ; toutes les requetes
--      data passent ensuite avec le JWT de l'utilisateur (role authenticated).
--   3) Restreindre les policies a authenticated :
--
--  Exemple (a activer APRES l'ajout de l'auth) :
--    drop policy if exists "public read"   on public.prospects_statuts;
--    drop policy if exists "public insert"  on public.prospects_statuts;
--    drop policy if exists "public update"  on public.prospects_statuts;
--    create policy "auth read"   on public.prospects_statuts for select to authenticated using (true);
--    create policy "auth insert" on public.prospects_statuts for insert to authenticated with check (true);
--    create policy "auth update" on public.prospects_statuts for update to authenticated using (true) with check (true);
--    -- (idem _historique en insert/select, _enrichissement en select seul)
--    -- => le role anon ne peut alors plus rien lire ni ecrire.
--
--  Raffinement moindre privilege (optionnel, apres avoir verifie que les
--  scripts Python d'enrichissement utilisent bien la SERVICE ROLE) :
--    - prospects_enrichissement : retirer insert/update a anon (lecture seule).
--    - prospects_historique     : retirer update a anon (insert + select seuls).

-- ============================================================================
--  SECTION 3 — URGENT : EXPOSITION INTER-PROJETS (donnees InkBook)
-- ============================================================================
--
--  Ce projet Supabase est PARTAGE avec le SaaS InkBook. Les tables suivantes
--  ont RLS DESACTIVEE (0 policy) -> exposees a la cle anon publique de la
--  prospection (presente dans un repo GitHub PUBLIC et dans le HTML servi) :
--
--      ClientPortalNote, ConsentRecord, RebookingSuggestion,
--      Transaction, WorkspaceMember
--
--  IMPACT : quiconque recupere cette cle peut lire/modifier/supprimer des
--  donnees clients, des CONSENTEMENTS et des PAIEMENTS InkBook. RGPD-critique.
--
--  NE PAS se contenter de "alter table ... enable row level security" : sans
--  policy, cela BLOQUERAIT InkBook. Il faut, dans le PROJET InkBook :
--    1) Activer RLS sur CHAQUE table, ET
--    2) Ecrire des policies par espace de travail / auth.uid().
--  Recommandation forte en parallele :
--    - SEPARER les deux apps dans deux projets Supabase distincts, et
--    - ROTER la cle anon/publishable (elle a fuite via un repo public).
--
--  (Non applique ici pour ne pas casser InkBook — decision + action cote InkBook.)
