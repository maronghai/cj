model deepseek-v4-flash-free
stream false
messages+
  role system
  content 1
  ,
  role user
  content ls
tools*
  type function
  function
    name get_weather
    description Get weather of a location, the user should supply a location first.
    parameters
      type object
      properties
        location
          type string
          description The city and state, e.g. San Francisco, CA
      required*
        location
  ,
  type function
  function
    name ls
    description ls files
    parameters
      type object
      properties
        location
          type string
          description the dir, default is .
      required*
        location