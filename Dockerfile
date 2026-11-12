FROM public.ecr.aws/lambda/python:3.12

ENV HF_HOME=/tmp/hf \
    TRANSFORMERS_OFFLINE=1

RUN pip install --no-cache-dir torch==2.15.0 --index-url https://download.pytorch.org/whl/cpu \
 && pip install --no-cache-dir transformers==5.22.2
COPY ner-model ${LAMBDA_TASK_ROOT}/ner-model
COPY app.py ${LAMBDA_TASK_ROOT}/
RUN chmod -R a+rX ${LAMBDA_TASK_ROOT}

CMD ["app.handler"]
