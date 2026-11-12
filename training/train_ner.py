"""Fine-tune DistilBERT (cased) for named-entity recognition on CoNLL-2003.

Run on a GPU (for example a free Colab T4):
    pip install transformers datasets evaluate seqeval accelerate
    python train_ner.py
Output: ./ner-model (model and tokenizer), plus entity-level F1 for validation and test.
"""
import numpy as np
import evaluate
from datasets import load_dataset
from transformers import (AutoModelForTokenClassification, AutoTokenizer,
                          DataCollatorForTokenClassification, Trainer,
                          TrainingArguments)

MODEL_CKPT = "distilbert-base-cased"

try:
    ds = load_dataset("tomaarsen/conll2003")
except Exception as e:
    print("First dataset source failed:", e)
    ds = load_dataset("eriktks/conll2003", revision="refs/convert/parquet")

label_names = ds["train"].features["ner_tags"].feature.names
id2label = dict(enumerate(label_names))
label2id = {l: i for i, l in id2label.items()}

tok = AutoTokenizer.from_pretrained(MODEL_CKPT)


def tokenize_align(batch):
    enc = tok(batch["tokens"], truncation=True, is_split_into_words=True)
    all_labels = []
    for i, tags in enumerate(batch["ner_tags"]):
        prev, lab = None, []
        for w in enc.word_ids(batch_index=i):
            if w is None or w == prev:
                lab.append(-100)  # ignored by the loss: special tokens and word continuations
            else:
                lab.append(tags[w])
            prev = w
        all_labels.append(lab)
    enc["labels"] = all_labels
    return enc


tokenized = ds.map(tokenize_align, batched=True, remove_columns=ds["train"].column_names)

model = AutoModelForTokenClassification.from_pretrained(
    MODEL_CKPT, num_labels=len(label_names), id2label=id2label, label2id=label2id)

seqeval = evaluate.load("seqeval")


def to_labels(predictions, labels):
    preds = np.argmax(predictions, axis=-1)
    true_pred = [[label_names[p] for p, l in zip(pr, lb) if l != -100] for pr, lb in zip(preds, labels)]
    true_lab = [[label_names[l] for p, l in zip(pr, lb) if l != -100] for pr, lb in zip(preds, labels)]
    return true_pred, true_lab


def compute_metrics(p):
    logits, labels = p
    tp, tl = to_labels(logits, labels)
    r = seqeval.compute(predictions=tp, references=tl)
    return {"precision": r["overall_precision"], "recall": r["overall_recall"],
            "f1": r["overall_f1"], "accuracy": r["overall_accuracy"]}


args = TrainingArguments(
    output_dir="ner-out", eval_strategy="epoch", save_strategy="no",
    learning_rate=2e-5, per_device_train_batch_size=32, per_device_eval_batch_size=64,
    num_train_epochs=3, weight_decay=0.01, fp16=True, report_to="none")

trainer = Trainer(
    model=model, args=args,
    train_dataset=tokenized["train"], eval_dataset=tokenized["validation"],
    data_collator=DataCollatorForTokenClassification(tok),
    compute_metrics=compute_metrics)
trainer.train()


def manual_f1(split):
    out = trainer.predict(tokenized[split])
    tp, tl = to_labels(out.predictions, out.label_ids)
    return round(seqeval.compute(predictions=tp, references=tl)["overall_f1"], 4)


print("validation F1:", manual_f1("validation"))
print("test F1:", manual_f1("test"))

trainer.save_model("ner-model")
tok.save_pretrained("ner-model")
