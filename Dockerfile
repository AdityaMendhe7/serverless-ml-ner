FROM public.ecr.aws/lambda/python:3.12

ENV HF_HOME=/tmp/hf \
    TRANSFORMERS_OFFLINE=1

RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu \
 && pip install --no-cache-dir transformers

COPY ner-model ${LAMBDA_TASK_ROOT}/ner-model
COPY app.py ${LAMBDA_TASK_ROOT}/
RUN chmod -R a+rX ${LAMBDA_TASK_ROOT}

CMD ["app.handler"]
