require "./base.cr"

module Invidious::Database::PlayerPos
  extend self

  def update_player_pos(user : User, vid : String, ts : Int32)
    request = <<-SQL
      INSERT INTO player_pos (user_id, video_id, pos, updated)
      VALUES ($1, $2, $3, now())
      ON CONFLICT (user_id, video_id) DO UPDATE SET pos = $3, updated = now()
    SQL

    PG_DB.exec(request, user.email, vid, ts)
  end

  def select(user : User, vid : String) : {Int32, Time}?
    request = <<-SQL
      SELECT pos, updated FROM player_pos
      WHERE user_id = $1 AND video_id = $2
      LIMIT 1
    SQL

    PG_DB.query_one?(request, user.email, vid, as: {Int32, Time})
  end
end
