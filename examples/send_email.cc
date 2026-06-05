# send_email — three required string params
model gpt-4o-mini
tools*
    type function
    function
        name send_email
        description Send an email to a recipient
        parameters
            type object
            properties
                to
                    type string
                    description Recipient email address
                subject
                    type string
                    description Email subject line
                body
                    type string
                    description Email body content
            required*
                to
                subject
                body
