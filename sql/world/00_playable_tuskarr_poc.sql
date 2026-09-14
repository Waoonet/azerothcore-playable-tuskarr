-- Playable Tuskarr Milestone 2 proof-of-concept world data.
-- TARGET: AzerothCore commit 413bea61a85e20d9caef7d66fc601a661fdddd9d
-- STATUS: STAGING ONLY. Do not run on a production realm until the staged DBC/client
--         package has passed the Milestone-2 validation gate.
--
-- Race 17 = Alliance Tuskarr
-- Race 18 = Horde Tuskarr
-- Classes: Warrior (1), Hunter (3), Shaman (7)
-- Start: Kamagua / Howling Fjord, map 571, zone 495.
-- Coordinates use AzerothCore's stock Kamagua game_tele position.

START TRANSACTION;

DELETE FROM `playercreateinfo`
WHERE `race` IN (17,18);

INSERT INTO `playercreateinfo`
(`race`,`class`,`map`,`zone`,`position_x`,`position_y`,`position_z`,`orientation`) VALUES
(17,1,571,495,774.043,-2940.65,7.36477,1.41719),
(17,3,571,495,774.043,-2940.65,7.36477,1.41719),
(17,7,571,495,774.043,-2940.65,7.36477,1.41719),
(18,1,571,495,774.043,-2940.65,7.36477,1.41719),
(18,3,571,495,774.043,-2940.65,7.36477,1.41719),
(18,7,571,495,774.043,-2940.65,7.36477,1.41719);

-- Keep racial stat modifiers neutral during the proof-of-concept. Final race balance
-- will be decided separately; the planned +1% Stamina racial is not implemented here.
DELETE FROM `player_race_stats`
WHERE `Race` IN (17,18);

INSERT INTO `player_race_stats`
(`Race`,`Strength`,`Agility`,`Stamina`,`Intellect`,`Spirit`) VALUES
(17,0,0,0,0,0),
(18,0,0,0,0,0);

-- Initial bars intentionally contain class fundamentals only. No Human, Draenei,
-- Tauren, Orc, or other stock racial ability is copied.
DELETE FROM `playercreateinfo_action`
WHERE `race` IN (17,18);

INSERT INTO `playercreateinfo_action`
(`race`,`class`,`button`,`action`,`type`) VALUES
-- Warrior
(17,1,72,6603,0),(17,1,73,78,0),(17,1,84,6603,0),(17,1,96,6603,0),
(18,1,72,6603,0),(18,1,73,78,0),(18,1,84,6603,0),(18,1,96,6603,0),
-- Hunter
(17,3,0,6603,0),(17,3,1,2973,0),(17,3,2,75,0),
(18,3,0,6603,0),(18,3,1,2973,0),(18,3,2,75,0),
-- Shaman
(17,7,0,6603,0),(17,7,1,403,0),(17,7,2,331,0),
(18,7,0,6603,0),(18,7,1,403,0),(18,7,2,331,0);

-- No custom racials, Kalu'ak reputation, starter quests, trainers, mounts, or
-- low-level Kamagua creature spawns are installed in Milestone 2. Those belong to
-- later milestones after the base race/client login proof succeeds.

COMMIT;
