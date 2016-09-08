require 'httparty'
require 'yaml'
require 'logger'
require 'sequel'
require_relative 'lib/update'

$log = Logger.new(STDOUT)  
token = YAML.load_file('config/secrets.yaml')["tumibot"]["token"]
last_offset = YAML.load_file('config/offset.yaml')['offset']
confidence = YAML.load_file('config/user_confidence_levels.yaml')

def bot_should_post(chats, confidence)  
  if confidence.fetch(chats.from_username, nil).nil?
    $log.info("#{chats.from_username} info not found")
    return false
  end

  if rand() > confidence[chats.from_username]['level']
     $log.info("#{chats.from_username} exceeded confidence level #{confidence[chats.from_username]['level']}")
     return true
  end
end

def reply_to_message(message_id, group_id, text, token)
  options = {
    body: {
      chat_id: group_id,
      text: text,
      reply_to_message_id: message_id
    }
  }
  $log.debug("Posting #{text} to #{group_id}")
  response = HTTParty.post("https://api.telegram.org/bot#{token}/sendMessage",options)
  $log.debug response
end

def write_offset_to_file(last_offset)
  data = {}
  data['offset'] = last_offset
  File.write('offset.yaml', YAML.dump(data))
  $log.debug("offset at: #{last_offset}, wrote to file")
end

while true
  response = HTTParty.get("https://api.telegram.org/bot#{token}/getUpdates?offset=#{last_offset+1}")
  $log.debug("Response: #{response}")
  if response['ok']
    result = response['result']
    result.each do |r|
      chats = Update.new
      chats.update_id = r['update_id']

      # if a message has been edited then the hash key changes from 
      # 'message' to edited message. So we replace them with below

      r['message'] = r.delete 'edited_message' if r['message'].nil?
      chats.message_id = r['message']['message_id']
      chats.from_id = r['message']['from']['id']
      chats.from_first_name = r['message']['from']['first_name']
      chats.from_last_name = r['message']['from']['last_name']
      chats.from_username = r['message']['from']['username']
      chats.group_title = r['message']['chat']['title']
      chats.group_id = r['message']['chat']['id']
      chats.chat_text = r['message']['text']
      if r['message']['forward_from'].nil?
        chats.chat_received_date = r['message']['date']
        chats.forwarded_chat = 'N'
      else
        chats.chat_received_date = r['message']['forward_date']
        chats.forwarded_chat = 'Y'
      end

      begin
        chats.save
      rescue Sequel::UniqueConstraintViolation => e
        $log.debug("Warning: Unique constraint error raised on #{chats.update_id}")
      end

      if bot_should_post(chats, confidence) and r['message']['new_chat_participant'].nil? and r['message']['left_chat_participant'].nil?
        what_to_post = confidence.fetch(chats.from_username).fetch('chats', nil)
        reply_to_message(chats.message_id, chats.group_id, what_to_post.sample, token) if not what_to_post.nil?
      end

      write_offset_to_file(chats.update_id)
    end
  end
end
