;; Example of gauche.selector

(use gauche.net)
(use gauche.selector)
(use gauche.uvector)

(define (echo-server port)
  (let ((selector (make <selector>))
        (servers  (make-server-sockets #f port :reuse-addr? #t)))

    (define (echo client input output)
      (let ((str (guard (e (else (eof-object)))
                   (read-uvector <u8vector> 4096 input))))
        (if (eof-object? str)
            (begin (format #t "client disconnected (~a)~%" (socket-address client))
                   (selector-delete! selector (socket-fd client) #f #f)
                   (socket-close client))
            (begin (write-uvector str output)
                   (flush output)))))

    (for-each
     (lambda (server)

       (define (accept-handler sock flag)
         (let* ((client (socket-accept server))
                (input  (socket-input-port client :buffering :none))
                (output (socket-output-port client)))
           (format #t "client connected (~a)~%" (socket-address client))
           (selector-add! selector
                          (socket-fd client)
                          (lambda (sock flag)
                            (echo client input output))
                          '(r))))

       (selector-add! selector
                      (socket-fd server)
                      accept-handler
                      '(r)))
     servers)
    (do () (#f) (selector-select selector))))

(define (main args)
  (define port 3131)
  (format #t "echo server starting on port ~d~%" port)
  (echo-server port)
  0)
