-- Table: public.player_pos

-- DROP TABLE public.player_pos;

CREATE TABLE IF NOT EXISTS public.player_pos
(
    video_id text,
    user_id text,
    pos integer,
    PRIMARY KEY (video_id,user_id)
);

GRANT ALL ON TABLE public.player_pos TO current_user;
